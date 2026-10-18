@preconcurrency import AVFoundation
import Foundation

protocol MicrophoneCaptureDeviceProtocol: AnyObject {
    func start(onPCM: @escaping (Data, UInt64) -> Void, onError: @escaping () -> Void,
        completion: @escaping (Result<Void, Error>) -> Void)
    func stop()
}

/// Lifecycle work may wait for the system audio service. It shares the same
/// coordinator as AudioOutput and never changes AVAudioSession independently.
final class MicrophoneCaptureDevice: MicrophoneCaptureDeviceProtocol {
    private let token = UUID()
    private let queue = DispatchQueue(label: "EternalMonitor.microphone.lifecycle", qos: .userInitiated)
    private let coordinator: AudioSessionCoordinator
    private var processor: MicrophoneCaptureProcessor?
    private let gate = NSLock()

    init(coordinator: AudioSessionCoordinator = .shared) { self.coordinator = coordinator }

    func start(onPCM: @escaping (Data, UInt64) -> Void, onError: @escaping () -> Void,
        completion: @escaping (Result<Void, Error>) -> Void) {
        let processor = MicrophoneCaptureProcessor(onPCM: onPCM, onError: onError)
        gate.lock(); self.processor = processor; gate.unlock()
        queue.async { [self] in
            let result = Result { try coordinator.startMicrophone(token: token, processor: processor) }
            if case .failure = result { processor.stop() }
            completion(result)
        }
    }

    func stop() {
        gate.lock(); let previous = processor; processor = nil; gate.unlock()
        // Close the realtime data gate before waiting for a pending start.
        previous?.stopAccepting()
        queue.sync { coordinator.stopMicrophone(token: token) }
        previous?.stop()
    }
}

/// The tap copies only a bounded amount of PCM and schedules at most one
/// worker. AVAudioConverter and packetization run off the realtime I/O thread.
final class MicrophoneCaptureProcessor: @unchecked Sendable {
    static let maximumQueuedBuffers = 3
    private struct Item { let buffer: AVAudioPCMBuffer; let timestampUs: UInt64; let reset: Bool }
    private let lock = NSLock()
    private var accepting = true
    private var scheduled = false
    private var pending: [Item] = []
    private let queue = DispatchQueue(label: "EternalMonitor.microphone.convert", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var accumulator = MicrophoneFrameAccumulator()
    private let onPCM: (Data, UInt64) -> Void
    private let onError: () -> Void

    init(onPCM: @escaping (Data, UInt64) -> Void, onError: @escaping () -> Void) {
        self.onPCM = onPCM; self.onError = onError
    }

    func offer(_ buffer: AVAudioPCMBuffer, timestampUs: UInt64) {
        guard buffer.frameLength > 0, buffer.frameLength <= 8192,
              buffer.format.channelCount > 0, buffer.format.channelCount <= 8 else { return }
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if pending.count == Self.maximumQueuedBuffers {
            pending.removeFirst()
            let first = pending[0]
            pending[0] = Item(buffer: first.buffer, timestampUs: first.timestampUs, reset: true)
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            lock.unlock(); return
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { lock.unlock(); return }
        for index in 0..<source.count {
            if let sourceData = source[index].mData, let destinationData = destination[index].mData {
                memcpy(destinationData, sourceData, min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize)))
            }
        }
        pending.append(Item(buffer: copy, timestampUs: timestampUs, reset: false))
        let startWorker = !scheduled
        scheduled = true
        lock.unlock()
        if startWorker { queue.async { [weak self] in self?.drain() } }
    }

    func stopAccepting() {
        lock.lock(); accepting = false; pending.removeAll(); lock.unlock()
    }

    func fail() {
        lock.lock()
        let notify = accepting
        accepting = false
        pending.removeAll()
        lock.unlock()
        if notify { onError() }
    }

    func stop() {
        stopAccepting()
        queue.sync { converter = nil; inputFormat = nil; accumulator.reset() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard accepting, !pending.isEmpty else {
                scheduled = false
                lock.unlock()
                return
            }
            let item = pending.removeFirst()
            lock.unlock()
            do { try convert(item) }
            catch {
                fail()
                return
            }
        }
    }

    private func convert(_ item: Item) throws {
        if item.reset || inputFormat != item.buffer.format {
            accumulator.reset()
            guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: item.buffer.format, to: output) else {
                throw MicrophoneAudioError.conversion
            }
            converter.primeMethod = .none
            self.converter = converter
            inputFormat = item.buffer.format
        }
        guard let converter else { throw MicrophoneAudioError.conversion }
        let capacity = AVAudioFrameCount(ceil(Double(item.buffer.frameLength) * 16_000 / item.buffer.format.sampleRate) + 64)
        guard capacity <= 16_448,
              let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw MicrophoneAudioError.conversion
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return item.buffer
        }
        guard status != .error, error == nil else { throw MicrophoneAudioError.conversion }
        guard converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }
        // All supported iPad/simulator targets are little-endian; the converter
        // produced signed Int16 mono, exactly the specified wire sample type.
        let pcm = Data(bytes: samples, count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
        accumulator.append(pcm: pcm, captureTimestampUs: item.timestampUs, emit: onPCM)
    }
}
