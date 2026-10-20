@preconcurrency import AVFoundation
import Foundation
import os

struct AudioStats: Equatable {
    var packets: UInt64 = 0
    var decoded: UInt64 = 0
    var lost: UInt64 = 0
    var bufferMs = 0
    var targetMs = 60
    var playing = false
    var rms = 0.0
    var tone1kDB = -120.0
    var error: String?
}

final class AudioPlayer {
    private struct Incoming {
        var packets: [ReceivedAudio] = []
        var enabled = true
        var stopped = false
    }
    private let incoming = OSAllocatedUnfairLock(initialState: Incoming())
    private let measurements = OSAllocatedUnfairLock(initialState: AudioStats())
    private let queue = DispatchQueue(label: "eternal.audio", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let outputQueue = DispatchQueue(label: "eternal.audio.output", qos: .userInteractive)
    private let pcm = AudioPCMBuffer(meterEnabled: E2E.enabled)
    private var timeline: AudioTimeline?
    private let output: AudioOutputDevice
    private var outputRunning = false
    private var outputRequested = false
    private var outputGeneration: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var failed = false
    private var interrupted = false
    private var lastPacketUs: UInt64 = 0
    private var lastLogUs: UInt64 = 0
    private var previousPackets: UInt64 = 0
    private var previousDecoded: UInt64 = 0
    private var previousLost: UInt64 = 0
    var onError: ((String) -> Void)?

    init(output: AudioOutputDevice = AudioOutput()) {
        self.output = output
        queue.setSpecific(key: queueKey, value: true)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.process() }
        self.timer = timer
        timer.resume()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] notice in
            guard let rawType = notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            self?.queue.async { [weak self] in
                guard let self, !self.incoming.withLock({ $0.stopped }) else { return }
                if type == .began {
                    self.interrupted = true
                    self.closeOutput(deactivate: false)
                    self.retireTimeline()
                    self.measurements.withLock { $0.playing = false; $0.bufferMs = 0 }
                } else {
                    // Dictation can invalidate the graph before its ended
                    // notification arrives. Retire that failure and old PCM;
                    // only the next real PC packet may open a fresh lease.
                    self.prepareForRecovery(deactivate: false)
                }
            }
        })
        // AudioSessionCoordinator owns hardware route/configuration changes.
        // A route notification can be caused by enabling VoiceProcessing on
        // that same engine. Releasing this playback lease in response used
        // to stop the newly opened microphone, then recreate its I/O unit
        // again when the next PC audio packet arrived.
    }

    deinit {
        timer?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        outputQueue.sync { output.stop(deactivate: true) }
    }

    var stats: AudioStats { measurements.withLock { $0 } }

    func receive(header: AudioHeader, opus: Data) {
        let now = ControlChannel.clientNowUs()
        incoming.withLock { s in
            guard s.enabled, !s.stopped else { return }
            if s.packets.count == 8 { s.packets.removeFirst() }
            s.packets.append(ReceivedAudio(header: header, opus: opus, receivedUs: now))
        }
    }

    func setEnabled(_ enabled: Bool) {
        incoming.withLock { $0.enabled = enabled; $0.packets.removeAll(keepingCapacity: true) }
        queue.async { [weak self] in
            guard let self else { return }
            self.closeOutput(deactivate: true)
            self.retireTimeline()
            self.failed = false
            if enabled { self.interrupted = false }
            self.measurements.withLock {
                $0.playing = false; $0.bufferMs = 0; $0.error = nil
            }
        }
    }

    func handleForeground() {
        queue.async { [weak self] in
            guard let self, self.incoming.withLock({ $0.enabled && !$0.stopped }),
                  self.failed || self.interrupted else { return }
            // Some system input sessions do not deliver an ended event to
            // this player. Returning to the app is an explicit recovery point,
            // while a healthy graph must remain untouched.
            self.prepareForRecovery(deactivate: false)
        }
    }

    func stop() {
        incoming.withLock { $0.stopped = true; $0.packets.removeAll() }
        let cleanup = {
            self.timer?.cancel(); self.timer = nil
            self.closeOutput(deactivate: true)
            self.timeline = nil
            self.measurements.withLock { $0 = AudioStats() }
        }
        // Finish old-session output before a USB takeover activates its player.
        if DispatchQueue.getSpecific(key: queueKey) == true { cleanup() }
        else { queue.sync(execute: cleanup) }
        // A pending start must close before a replacement player's session is
        // activated. The output worker never waits for the packet queue.
        outputQueue.sync {}
    }

    private func process() {
        let packets = incoming.withLock { s -> [ReceivedAudio] in
            guard s.enabled, !s.stopped else { return [] }
            let batch = s.packets
            s.packets.removeAll(keepingCapacity: true)
            return batch
        }
        guard !failed, !interrupted else { return }
        let now = ControlChannel.clientNowUs()
        do {
            if !packets.isEmpty {
                if timeline == nil { timeline = try AudioTimeline(pcm: pcm) }
                for packet in packets { try timeline?.receive(packet) }
                lastPacketUs = packets.last?.receivedUs ?? now
            }
            guard let timeline else { return }
            try timeline.drain(nowUs: now)
            if !packets.isEmpty, !outputRequested { openOutput() }
            let buffer = pcm.snapshot
            let stats = AudioStats(packets: previousPackets + timeline.packets,
                decoded: previousDecoded + timeline.decoded,
                lost: previousLost + timeline.lost, bufferMs: buffer.bufferMs + timeline.pendingCount * 20,
                targetMs: buffer.targetMs,
                playing: outputRunning && now >= lastPacketUs && now - lastPacketUs < 500_000,
                rms: buffer.rms, tone1kDB: buffer.tone1kDB)
            measurements.withLock { $0 = stats }
            if E2E.enabled, now - lastLogUs >= 1_000_000 {
                lastLogUs = now
                E2E.audio(stats)
            }
        } catch {
            fail(error)
        }
    }

    private func openOutput() {
        guard canPlay, !failed else { return }
        outputRequested = true
        let generation = outputGeneration
        let queue = self.queue
        outputQueue.async { [weak self, output, pcm] in
            // Install and snapshot the handler on the same output owner as
            // start(). A delayed failure belongs to this lease generation.
            output.setGraphFailureHandler { [weak self] error in
                queue.async { [weak self] in
                    guard let self, self.acceptsOutputResult(generation: generation) else { return }
                    self.fail(error)
                }
            }
            let result = Result { try output.start(pcm: pcm) }
            queue.async { [weak self] in
                guard let self, self.acceptsOutputResult(generation: generation) else { return }
                switch result {
                case .success: self.outputRunning = true
                case .failure(let error): self.fail(error)
                }
            }
        }
    }

    private var canPlay: Bool {
        !interrupted && incoming.withLock { $0.enabled && !$0.stopped }
    }

    private func acceptsOutputResult(generation: UInt64) -> Bool {
        outputGeneration == generation && outputRequested && canPlay
    }

    private func prepareForRecovery(deactivate: Bool) {
        incoming.withLock { $0.packets.removeAll(keepingCapacity: true) }
        closeOutput(deactivate: deactivate)
        retireTimeline()
        failed = false
        interrupted = false
        measurements.withLock { $0.playing = false; $0.bufferMs = 0; $0.error = nil }
    }

    private func fail(_ error: Error) {
        failed = true
        closeOutput(deactivate: true)
        let message = "PC audio stopped: \(error.localizedDescription)"
        measurements.withLock { $0.playing = false; $0.error = "声音不可用，请重新连接后重试。" }
        onError?(message)
    }

    private func retireTimeline() {
        if let timeline {
            previousPackets += timeline.packets
            previousDecoded += timeline.decoded
            previousLost += timeline.lost
        }
        timeline = nil
    }

    private func closeOutput(deactivate: Bool) {
        outputGeneration &+= 1
        outputRequested = false
        outputRunning = false
        pcm.reset()
        outputQueue.async { [output] in output.stop(deactivate: deactivate) }
    }
}
