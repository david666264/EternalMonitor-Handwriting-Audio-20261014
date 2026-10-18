import Foundation

/// A small live-audio queue, independent of reliable keyboard jobs. Slow USB
/// drops old speech frames instead of retaining audio indefinitely or filling
/// FramedLink's control buffer. There is only one transport batch in flight.
final class MicrophoneUplink: @unchecked Sendable {
    typealias BatchTransport = ([Data], @escaping (Bool) -> Void) -> Void
    static let maximumQueuedFrames = 3
    struct Snapshot { var queued = 0; var dropped: UInt64 = 0; var inFlight = false }
    private struct State {
        var sessionId: UInt32 = 0
        var lastSessionId: UInt32 = 0
        var sequence: UInt32 = 0
        var generation: UInt64 = 0
        var pending: [Data] = []
        var scheduled = false
        var inFlight = false
        var dropped: UInt64 = 0
        var send: BatchTransport?
    }
    private let lock = NSLock()
    private var state = State()
    private let queue = DispatchQueue(label: "EternalMonitor.microphone.uplink", qos: .userInitiated)

    func start(sessionId: UInt32, sendBatch: @escaping BatchTransport) {
        lock.lock()
        state.generation &+= 1
        state.sessionId = sessionId
        if state.lastSessionId != sessionId { state.sequence = 0 }
        state.lastSessionId = sessionId
        state.pending.removeAll(keepingCapacity: true)
        state.scheduled = false
        state.inFlight = false
        state.dropped = 0
        state.send = sessionId == 0 ? nil : sendBatch
        lock.unlock()
    }

    func offer(pcm: Data, timestampUs: UInt64) {
        guard pcm.count == MicrophoneHeader.payloadSize else { return }
        lock.lock()
        guard state.sessionId != 0, state.send != nil else { lock.unlock(); return }
        let header = MicrophoneHeader(sessionId: state.sessionId, microphoneSeq: state.sequence, captureTimestampUs: timestampUs)
        state.sequence &+= 1
        guard let packet = header.encode(pcm: pcm) else { lock.unlock(); return }
        if state.pending.count == Self.maximumQueuedFrames {
            state.pending.removeFirst()
            state.dropped &+= 1
        }
        state.pending.append(packet)
        let schedule = !state.scheduled
        state.scheduled = true
        let generation = state.generation
        lock.unlock()
        if schedule { queue.async { [weak self] in self?.pump(generation: generation) } }
    }

    /// Stop accepting immediately. The end marker is best effort and contains
    /// no PCM; disconnect still closes the authenticated stream on the host.
    func stop(sendEnd: Bool = true) {
        lock.lock()
        let sender = state.send
        let end = state.sessionId == 0 ? nil : MicrophoneHeader(sessionId: state.sessionId,
            microphoneSeq: state.sequence, captureTimestampUs: ControlChannel.clientNowUs(), isEnd: true).encode(pcm: Data())
        if end != nil { state.sequence &+= 1 }
        state.generation &+= 1
        state.sessionId = 0
        state.pending.removeAll(keepingCapacity: true)
        state.send = nil
        state.scheduled = false
        state.inFlight = false
        lock.unlock()
        if sendEnd, let sender, let end {
            // Ordered behind a pump that already took a frame. Never let an
            // old frame arrive after this session's end marker.
            queue.async { sender([end]) { _ in } }
        }
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(queued: state.pending.count, dropped: state.dropped, inFlight: state.inFlight)
    }

    private func pump(generation: UInt64) {
        lock.lock()
        guard state.generation == generation, !state.inFlight else { lock.unlock(); return }
        guard state.sessionId != 0, let sender = state.send, !state.pending.isEmpty else {
            state.scheduled = false
            lock.unlock()
            return
        }
        let packet = state.pending.removeFirst()
        state.inFlight = true
        lock.unlock()
        sender([packet]) { [weak self] success in
            guard let self else { return }
            self.lock.lock()
            guard self.state.generation == generation, self.state.inFlight else { self.lock.unlock(); return }
            self.state.inFlight = false
            if !success { self.state.dropped &+= 1 }
            self.lock.unlock()
            self.queue.async { [weak self] in self?.pump(generation: generation) }
        }
    }
}

/// The converter can return variable-sized PCM buffers. Retain at most one
/// partial 20 ms frame; complete frames leave synchronously to a bounded sink.
struct MicrophoneFrameAccumulator {
    private var partial = Data()
    private var nextTimestampUs: UInt64?

    mutating func reset() { partial.removeAll(keepingCapacity: true); nextTimestampUs = nil }

    mutating func append(pcm: Data, captureTimestampUs: UInt64, emit: (Data, UInt64) -> Void) {
        guard pcm.count.isMultiple(of: 2), !pcm.isEmpty else { return }
        // A capture drop must not stitch old and new speech into one frame.
        if let nextTimestampUs,
           captureTimestampUs > nextTimestampUs,
           captureTimestampUs - nextTimestampUs > 100_000 { reset() }
        if nextTimestampUs == nil { nextTimestampUs = captureTimestampUs }
        var offset = 0
        while offset < pcm.count {
            let count = min(MicrophoneHeader.payloadSize - partial.count, pcm.count - offset)
            let start = pcm.index(pcm.startIndex, offsetBy: offset)
            partial.append(pcm.subdata(in: start..<pcm.index(start, offsetBy: count)))
            offset += count
            if partial.count == MicrophoneHeader.payloadSize {
                let timestamp = nextTimestampUs ?? captureTimestampUs
                emit(partial, timestamp)
                partial.removeAll(keepingCapacity: true)
                nextTimestampUs = timestamp &+ 20_000
            }
        }
    }
}
