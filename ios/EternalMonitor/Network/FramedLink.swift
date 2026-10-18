import Foundation
import Network

/// An accepted USB tunnel. The preamble is validated before the app sees the
/// link; session setup then starts the same control and media path as UDP.
final class FramedLink: MediaLink {
    let datagrams = MediaDatagrams()
    let isUSB = true
    var onConnectionEstablished: (() -> Void)?
    var onError: ((String) -> Void)?
    var onListenerReady: ((UInt16) -> Void)?
    var onClosed: (() -> Void)?
    var onPreambleReady: (() -> Void)?

    private let queue = DispatchQueue(label: "com.eternal.usb", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var connection: NWConnection?
    private var framer = EMLinkFramer()
    private var preambleDeadline: DispatchWorkItem?
    private var announcedPreamble = false
    private var started = false
    private var bufferedPackets: [Data] = []
    private struct PendingSend {
        let data: Data
        let completion: ((Bool) -> Void)?
    }
    /// Bound bytes rather than packet count: a committed text document is a
    /// legitimate burst of many small control packets. Each TCP write stays
    /// small enough that inbound video/audio can keep making progress.
    static let maximumWriteBytes = 64 * 1024
    static let maximumPendingBytes = 256 * 1024
    private var pendingSends: [PendingSend] = []
    private var pendingSendBytes = 0
    private var activeCompletions: [(Bool) -> Void] = []
    private var sending = false

    var controlQueue: DispatchQueue { queue }

    init(connection: NWConnection) {
        self.connection = connection
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit { onQueue { stopOnQueue() } }

    private func onQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return operation() }
        return queue.sync(execute: operation)
    }

    func validatePreamble() {
        queue.async { [self] in
            guard let connection else { return }
            let deadline = DispatchWorkItem { [weak self] in self?.fail("USB handshake timed out.") }
            preambleDeadline = deadline
            queue.asyncAfter(deadline: .now() + .seconds(2), execute: deadline)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready: self.receiveNext()
                case .failed(let error): self.fail("USB connection failed: \(error.localizedDescription)")
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    @discardableResult
    func start(host: String) -> Bool {
        onQueue {
            guard connection != nil, framer.preambleReceived else { return false }
            guard !started else { return true }
            started = true
            onConnectionEstablished?()
            onListenerReady?(9877)
            let packets = bufferedPackets
            bufferedPackets.removeAll()
            for packet in packets { datagrams.handle(packet) }
            return true
        }
    }

    func send(_ data: Data) {
        enqueue([data], completion: nil)
    }

    /// Completion means Network.framework accepted these bytes, not that a
    /// particular Windows text field received them. Producers wait for this
    /// boundary before generating their next text chunk; no timed guessing.
    func sendBatch(_ datagrams: [Data], completion: @escaping (Bool) -> Void) {
        enqueue(datagrams, completion: completion)
    }

    /// Live audio is expendable under congestion. Unlike reliable keyboard
    /// input, it must never fill the USB queue or close a healthy video link.
    /// The sender allows one frame in flight; this guard executes on the same
    /// queue as enqueue, so no other writer can consume the checked budget.
    func sendMicrophoneBatch(_ datagrams: [Data], completion: @escaping (Bool) -> Void) {
        let write = { [self] in
            guard datagrams.count == 1, let packet = datagrams.first,
                  MicrophoneHeader.decode(packet) != nil, connection != nil,
                  pendingSendBytes + packet.count + 4 <= min(Self.maximumPendingBytes, 32 * 1024)
            else { completion(false); return }
            sendBatch(datagrams, completion: completion)
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { write() }
        else { queue.async(execute: write) }
    }

    private func enqueue(_ datagrams: [Data], completion: ((Bool) -> Void)?) {
        let write = { [self] in
            guard connection != nil else { completion?(false); return }
            var framed = Data()
            do {
                for datagram in datagrams {
                    let packet = try EMLinkFramer.encode(datagram)
                    guard framed.count + packet.count <= Self.maximumPendingBytes else {
                        completion?(false)
                        fail("USB input buffer is full; the text draft was retained.")
                        return
                    }
                    framed.append(packet)
                }
            } catch {
                completion?(false)
                fail("Invalid USB packet.")
                return
            }
            guard !framed.isEmpty else { completion?(true); return }
            guard pendingSendBytes + framed.count <= Self.maximumPendingBytes else {
                completion?(false)
                fail("USB input buffer is full; the text draft was retained.")
                return
            }
            var offset = 0
            while offset < framed.count {
                let end = min(framed.count, offset + Self.maximumWriteBytes)
                pendingSends.append(PendingSend(data: framed.subdata(in: offset..<end),
                    completion: end == framed.count ? completion : nil))
                offset = end
            }
            pendingSendBytes += framed.count
            sendNext()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { write() }
        else { queue.async(execute: write) }
    }

    private func sendNext() {
        guard let connection, !sending, !pendingSends.isEmpty else { return }
        sending = true
        // Coalesce already waiting controls without delaying any packet.
        // Framing permits a large logical batch to cross TCP write boundaries.
        var packet = Data()
        var count = 0
        var completions: [(Bool) -> Void] = []
        for pending in pendingSends {
            guard packet.count + pending.data.count <= Self.maximumWriteBytes else { break }
            packet.append(pending.data)
            if let completion = pending.completion { completions.append(completion) }
            count += 1
        }
        pendingSends.removeFirst(count)
        pendingSendBytes -= packet.count
        activeCompletions = completions
        connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection else { return }
            self.sending = false
            let completions = self.activeCompletions
            self.activeCompletions.removeAll()
            if let error {
                for completion in completions { completion(false) }
                self.fail("USB send failed: \(error.localizedDescription)")
            } else {
                for completion in completions { completion(true) }
                self.sendNext()
            }
        })
    }

    private func receiveNext() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data, !data.isEmpty {
                do {
                    let packets = try self.framer.append(data)
                    if self.framer.preambleReceived && !self.announcedPreamble {
                        self.announcedPreamble = true
                        self.preambleDeadline?.cancel()
                        self.preambleDeadline = nil
                        self.onPreambleReady?()
                    }
                    if self.started {
                        for packet in packets { self.datagrams.handle(packet) }
                    } else {
                        guard self.bufferedPackets.count + packets.count <= 64 else {
                            self.fail("USB data arrived before a session was ready."); return
                        }
                        self.bufferedPackets.append(contentsOf: packets)
                    }
                } catch {
                    self.fail("USB protocol mismatch."); return
                }
            }
            if let error { self.fail("USB receive failed: \(error.localizedDescription)") }
            else if complete { self.finish() }
            else { self.receiveNext() }
        }
    }

    func stop() { onQueue { stopOnQueue(flush: true) } }

    private func stopOnQueue(flush: Bool = false) {
        preambleDeadline?.cancel()
        preambleDeadline = nil
        if let closing = connection {
            closing.stateUpdateHandler = nil
            if flush {
                // The active send is already queued in Network.framework.
                // Append our bounded control queue and BYE before write-close.
                for packet in pendingSends {
                    closing.send(content: packet.data, completion: .contentProcessed { _ in })
                }
                closing.send(content: nil, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in closing.cancel() })
                queue.asyncAfter(deadline: .now() + .milliseconds(250)) { closing.cancel() }
            } else {
                closing.cancel()
            }
        }
        connection = nil
        bufferedPackets.removeAll()
        let completions = activeCompletions + pendingSends.compactMap(\.completion)
        activeCompletions.removeAll()
        pendingSends.removeAll()
        pendingSendBytes = 0
        sending = false
        datagrams.reset()
        for completion in completions { completion(false) }
    }

    private func fail(_ message: String) {
        guard connection != nil else { return }
        onError?(message)
        finish()
    }

    private func finish() {
        guard connection != nil else { return }
        stopOnQueue()
        onClosed?()
    }
}
