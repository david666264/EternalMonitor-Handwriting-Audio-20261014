@preconcurrency import AVFoundation
import Foundation
import os

protocol DuplexAudioHardware: AnyObject {
    var onConfigurationChange: ((ObjectIdentifier) -> Void)? { get set }
    func requiresRebuild(afterConfigurationChange identity: ObjectIdentifier) -> Bool
    func replacePlaybackWhileMicrophoneRuns(_ playback: AudioPCMBuffer?) -> Bool
    func rebuild(playback: AudioPCMBuffer?, microphone: MicrophoneCaptureProcessor?) throws
    func shutdown(deactivate: Bool)
}

extension DuplexAudioHardware {
    var onConfigurationChange: ((ObjectIdentifier) -> Void)? { get { nil } set {} }
    func requiresRebuild(afterConfigurationChange identity: ObjectIdentifier) -> Bool { false }
    func replacePlaybackWhileMicrophoneRuns(_ playback: AudioPCMBuffer?) -> Bool { false }
}

/// The only AVAudioSession/AVAudioEngine owner. Playback and microphone have
/// independent leases, so AudioOutput.start cannot change an active recording
/// session to playback-only, and stopping capture cannot deactivate TTS.
final class AudioSessionCoordinator: @unchecked Sendable {
    static let shared = AudioSessionCoordinator()
    private let queue = DispatchQueue(label: "EternalMonitor.audio.session", qos: .userInitiated)
    private let hardware: DuplexAudioHardware
    private var playback: (token: UUID, pcm: AudioPCMBuffer, onFailure: ((Error) -> Void)?)?
    private var microphone: (token: UUID, processor: MicrophoneCaptureProcessor)?
    private let logger = Logger(subsystem: "com.eternal.monitor", category: "microphone")

    init(hardware: DuplexAudioHardware? = nil) {
        let hardware = hardware ?? NativeDuplexAudioHardware()
        self.hardware = hardware
        hardware.onConfigurationChange = { [weak self] identity in
            // Apple posts on an internal audio queue. Never tear down an
            // engine there: enqueue its identity and inspect it on our owner.
            self?.queue.async { [weak self] in
                guard let self, self.playback != nil || self.microphone != nil,
                      self.hardware.requiresRebuild(afterConfigurationChange: identity) else { return }
                self.rebuildRemainingOrReportFailure(reason: "configuration-change")
            }
        }
    }

    /// Also makes queued hardware notifications observable in unit tests.
    func flushPendingHardwareChanges() { queue.sync {} }

    func startPlayback(token: UUID, pcm: AudioPCMBuffer, onFailure: ((Error) -> Void)? = nil) throws {
        try queue.sync {
            let previous = playback
            playback = (token, pcm, onFailure)
            do { try rebuild(reason: "playback-start", allowPlaybackReplacement: true) }
            catch {
                logFailure(error, reason: "playback-start")
                playback = previous
                rebuildRemainingOrReportFailure(reason: "playback-start-rollback")
                throw error
            }
        }
    }

    func stopPlayback(token: UUID, deactivate: Bool) {
        queue.sync {
            guard playback?.token == token else {
                if deactivate, playback == nil, microphone == nil { hardware.shutdown(deactivate: true) }
                return
            }
            playback = nil
            if microphone != nil {
                rebuildRemainingOrReportFailure(reason: "playback-stop", allowPlaybackReplacement: true)
            }
            else { hardware.shutdown(deactivate: deactivate) }
        }
    }

    func startMicrophone(token: UUID, processor: MicrophoneCaptureProcessor) throws {
        try queue.sync {
            let previous = microphone
            microphone = (token, processor)
            do { try rebuild(reason: "microphone-start") }
            catch {
                logFailure(error, reason: "microphone-start")
                microphone = previous
                // AEC/recording failure must leave an existing speaker lease
                // usable; raw, unprocessed microphone is never a fallback.
                rebuildRemainingOrReportFailure(reason: "microphone-start-rollback")
                throw error
            }
        }
    }

    func stopMicrophone(token: UUID) {
        queue.sync {
            guard microphone?.token == token else { return }
            microphone = nil
            if playback != nil { rebuildRemainingOrReportFailure(reason: "microphone-stop") }
            else { hardware.shutdown(deactivate: true) }
        }
    }

    private func rebuild(reason: String, allowPlaybackReplacement: Bool = false) throws {
        if playback == nil, microphone == nil { hardware.shutdown(deactivate: true) }
        else if allowPlaybackReplacement, microphone != nil,
                hardware.replacePlaybackWhileMicrophoneRuns(playback?.pcm) {
            logger.info("Audio playback lease updated without restarting microphone reason=\(reason, privacy: .public)")
        } else {
            logger.info("Audio graph rebuild reason=\(reason, privacy: .public) playback=\(self.playback != nil) microphone=\(self.microphone != nil)")
            try hardware.rebuild(playback: playback?.pcm, microphone: microphone?.processor)
        }
    }

    /// A lease is a request, not proof that a hardware graph survived. Notify
    /// whichever consumer remains if its rebuild fails; their existing stop
    /// paths release the same lease. Never silently retain a dead graph.
    private func rebuildRemainingOrReportFailure(reason: String, allowPlaybackReplacement: Bool = false) {
        do { try rebuild(reason: reason, allowPlaybackReplacement: allowPlaybackReplacement) }
        catch {
            logFailure(error, reason: reason)
            hardware.shutdown(deactivate: true)
            playback?.onFailure?(error)
            microphone?.processor.fail()
        }
    }

    private func logFailure(_ error: Error, reason: String) {
        let error = error as NSError
        // No localizedDescription/userInfo: they may contain device IDs or
        // paths. Static operation names and OS error domain/code suffice.
        logger.error("Audio graph failure reason=\(reason, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public) playback=\(self.playback != nil) microphone=\(self.microphone != nil)")
    }
}

/// The engine always has one source node. Playback leases change only this
/// pointer while microphone input remains active, keeping VoiceProcessing IO
/// alive. The render thread takes a strong snapshot before releasing the lock.
final class AudioPlaybackSlot: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<AudioPCMBuffer?>(initialState: nil)

    func replace(_ pcm: AudioPCMBuffer?) { state.withLock { $0 = pcm } }

    @discardableResult
    func render(frames: Int, buffers: UnsafeMutableAudioBufferListPointer, nowUs: UInt64) -> Bool {
        if let pcm = state.withLock({ $0 }) {
            pcm.render(frames: frames, buffers: buffers, nowUs: nowUs)
            return true
        }
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        return false
    }
}

enum MicrophoneAudioError: LocalizedError {
    case unavailable, conversion
    var errorDescription: String? {
        switch self {
        case .unavailable: return "麦克风或回声消除暂不可用，请换回 iPad 麦克风后重试。"
        case .conversion: return "麦克风格式无法转换，请重新开启麦克风。"
        }
    }
}

/// Playback and capture must share the actual I/O engine for Apple's voice
/// processor to receive the PC/TTS render reference used by echo cancellation.
private final class NativeDuplexAudioHardware: DuplexAudioHardware {
    var onConfigurationChange: ((ObjectIdentifier) -> Void)?
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var active = false
    private var playbackSlot: AudioPlaybackSlot?
    private var microphoneProcessor: MicrophoneCaptureProcessor?
    private var configurationObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.eternal.monitor", category: "microphone")

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] notification in
            guard let changed = notification.object as? AVAudioEngine else { return }
            // Queue a value, not the engine. Retaining the retired engine
            // until a replacement starts can keep its VoiceProcessing unit
            // alive and make the replacement's initialization fail.
            self?.onConfigurationChange?(ObjectIdentifier(changed))
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    func requiresRebuild(afterConfigurationChange identity: ObjectIdentifier) -> Bool {
        guard let engine, ObjectIdentifier(engine) == identity, !engine.isRunning else { return false }
        logger.notice("Current audio engine stopped after hardware configuration changed; rebuilding active leases")
        return true
    }

    func replacePlaybackWhileMicrophoneRuns(_ playback: AudioPCMBuffer?) -> Bool {
        guard let engine, engine.isRunning, microphoneProcessor != nil, let playbackSlot else { return false }
        playbackSlot.replace(playback)
        return true
    }

    func rebuild(playback: AudioPCMBuffer?, microphone: MicrophoneCaptureProcessor?) throws {
        shutdown(deactivate: false)
        let session = AVAudioSession.sharedInstance()
        var stage = "session-category"
        var buildingEngine: AVAudioEngine?
        do {
            if microphone != nil {
                let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]
                if session.category != .playAndRecord || session.mode != .voiceChat || session.categoryOptions != options {
                    try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
                }
            } else if session.category != .playback || session.mode != .default {
                try session.setCategory(.playback, mode: .default)
            }
            stage = "session-preferences"
            if session.preferredSampleRate != 48_000 { try session.setPreferredSampleRate(48_000) }
            if abs(session.preferredIOBufferDuration - 0.01) > 0.0001 { try session.setPreferredIOBufferDuration(0.01) }
            // An interruption or media service can deactivate the real session
            // without changing our bookkeeping. Always confirm activation.
            stage = "session-activate"
            try session.setActive(true)
            active = true
            let output = AVAudioEngine()
            buildingEngine = output
            stage = "voice-processing"
            if microphone != nil {
                try output.inputNode.setVoiceProcessingEnabled(true)
                guard output.inputNode.isVoiceProcessingEnabled else { throw MicrophoneAudioError.unavailable }
                output.inputNode.isVoiceProcessingInputMuted = false
                output.inputNode.isVoiceProcessingAGCEnabled = true
                output.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
                throw MicrophoneAudioError.unavailable
            }
            let slot = AudioPlaybackSlot()
            slot.replace(playback)
            let source = AVAudioSourceNode(format: format) { silence, _, frameCount, list in
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                silence.pointee = !slot.render(frames: Int(frameCount), buffers: buffers,
                    nowUs: ControlChannel.clientNowUs())
                return noErr
            }
            stage = "source-connect"
            output.attach(source)
            output.connect(source, to: output.mainMixerNode, format: format)
            if let microphone {
                stage = "input-format"
                let input = output.inputNode
                let hardwareFormat = input.inputFormat(forBus: 0)
                let inputFormat = input.outputFormat(forBus: 0)
                guard session.isInputAvailable, hardwareFormat.channelCount > 0,
                      (8_000...192_000).contains(hardwareFormat.sampleRate),
                      inputFormat.channelCount > 0, (8_000...192_000).contains(inputFormat.sampleRate) else {
                    throw MicrophoneAudioError.unavailable
                }
                logger.info("Microphone formats hardware=\(hardwareFormat.sampleRate)Hz/\(hardwareFormat.channelCount)ch tap=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch")
                stage = "input-tap"
                input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak microphone] buffer, _ in
                    let now = ControlChannel.clientNowUs()
                    let duration = UInt64(Double(buffer.frameLength) / buffer.format.sampleRate * 1_000_000)
                    microphone?.offer(buffer, timestampUs: now >= duration ? now - duration : 0)
                }
                tapInstalled = true
            }
            stage = "engine-prepare"
            output.prepare()
            stage = "engine-start"
            try output.start()
            engine = output
            playbackSlot = slot
            microphoneProcessor = microphone
            logger.info("Audio hardware running playback=\(playback != nil) microphone=\(microphone != nil)")
        } catch {
            let diagnostic = error as NSError
            logger.error("Audio hardware failure stage=\(stage, privacy: .public) domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code, privacy: .public)")
            if let output = buildingEngine {
                if tapInstalled { output.inputNode.removeTap(onBus: 0); tapInstalled = false }
                output.stop()
                releaseVoiceProcessing(on: output, hadMicrophone: microphone != nil)
            }
            throw error
        }
    }

    func shutdown(deactivate: Bool) {
        playbackSlot?.replace(nil)
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            releaseVoiceProcessing(on: engine, hadMicrophone: microphoneProcessor != nil)
        }
        tapInstalled = false
        engine = nil
        playbackSlot = nil
        microphoneProcessor = nil
        if deactivate, active {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            active = false
        }
    }

    private func releaseVoiceProcessing(on stoppedEngine: AVAudioEngine, hadMicrophone: Bool) {
        // stop() halts rendering, but a NotificationCenter delivery can still
        // retain the engine. Explicitly switch its stopped I/O back before a
        // replacement allocates another VoiceProcessing unit (-66635).
        // Never access inputNode for a playback-only graph: it is lazy.
        guard hadMicrophone else { return }
        let input = stoppedEngine.inputNode
        guard input.isVoiceProcessingEnabled else { return }
        do { try input.setVoiceProcessingEnabled(false) }
        catch {
            let diagnostic = error as NSError
            logger.error("Audio hardware failure stage=voice-processing-release domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code, privacy: .public)")
        }
    }
}
