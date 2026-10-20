import Foundation
import XCTest
@testable import EternalMonitor

final class MicrophoneUplinkTests: XCTestCase {
    private final class Transport {
        let lock = NSLock()
        var packets: [Data] = []
        private var batches: [[Data]] = []
        var completions: [(Bool) -> Void] = []
        var onSend: (() -> Void)?
        func send(_ packets: [Data], done: @escaping (Bool) -> Void) {
            lock.lock()
            self.packets.append(contentsOf: packets)
            self.batches.append(packets)
            completions.append(done)
            let callback = onSend
            lock.unlock()
            callback?()
        }
        func observe(_ callback: @escaping () -> Void) { lock.lock(); onSend = callback; lock.unlock() }
        func completeFirst(_ success: Bool = true) {
            lock.lock(); let callback = completions.removeFirst(); lock.unlock()
            callback(success)
        }
        var headers: [MicrophoneHeader] {
            lock.lock(); defer { lock.unlock() }
            return packets.compactMap { MicrophoneHeader.decode($0)?.header }
        }
        var batchSequences: [[UInt32]] {
            lock.lock(); defer { lock.unlock() }
            return batches.map { $0.compactMap { MicrophoneHeader.decode($0)?.header.microphoneSeq } }
        }
    }

    func testSlowTransportRetainsOnlyNewestEightFramesAndOneBatchInFlight() {
        let uplink = MicrophoneUplink()
        let transport = Transport()
        let first = expectation(description: "first send")
        transport.observe { first.fulfill() }
        uplink.start(sessionId: 7, sendBatch: transport.send)
        let pcm = Data(repeating: 0, count: 640)
        uplink.offer(pcm: pcm, timestampUs: 0)
        wait(for: [first], timeout: 2)
        for index in 1...100 { uplink.offer(pcm: pcm, timestampUs: UInt64(index * 20_000)) }
        XCTAssertEqual(transport.headers.count, 1)
        XCTAssertEqual(uplink.snapshot.queued, 8)
        XCTAssertTrue(uplink.snapshot.inFlight)
        XCTAssertEqual(uplink.snapshot.dropped, 92)
        let second = expectation(description: "freshest remaining send")
        transport.observe { second.fulfill() }
        transport.completeFirst()
        wait(for: [second], timeout: 2)
        XCTAssertEqual(transport.batchSequences, [[0], (93...100).map { UInt32($0) }])
        XCTAssertEqual(uplink.snapshot.queued, 0, "One completion must drain the entire bounded backlog")
        transport.observe {}
        uplink.stop(sendEnd: false)
        transport.completeFirst()
        XCTAssertEqual(uplink.snapshot.queued, 0)
    }

    func testNormalFiveFrameCaptureBurstsSurviveDelayedTransportCallbacks() {
        let uplink = MicrophoneUplink()
        let transport = Transport()
        let pcm = Data(repeating: 0x12, count: 640)
        let seed = expectation(description: "prior write is in flight")
        transport.observe { seed.fulfill() }
        uplink.start(sessionId: 7, sendBatch: transport.send)
        uplink.offer(pcm: pcm, timestampUs: 0)
        wait(for: [seed], timeout: 2)

        // Actual hardware delivers about five 20 ms frames per native tap.
        // Holding the previous completion makes this burst deterministic.
        var accumulator = MicrophoneFrameAccumulator()
        accumulator.append(pcm: Data(repeating: 0x34, count: 5 * 640), captureTimestampUs: 20_000) {
            uplink.offer(pcm: $0, timestampUs: $1)
        }
        XCTAssertEqual(uplink.snapshot.queued, 5)
        XCTAssertEqual(uplink.snapshot.dropped, 0)
        XCTAssertEqual(transport.batchSequences, [[0]], "Only one transport batch may be in flight")
        let firstBurst = expectation(description: "five frames share one completed write")
        transport.observe { firstBurst.fulfill() }
        transport.completeFirst()
        wait(for: [firstBurst], timeout: 2)
        XCTAssertEqual(transport.batchSequences, [[0], [1, 2, 3, 4, 5]])
        XCTAssertEqual(uplink.snapshot.queued, 0)

        accumulator.append(pcm: Data(repeating: 0x56, count: 5 * 640), captureTimestampUs: 120_000) {
            uplink.offer(pcm: $0, timestampUs: $1)
        }
        XCTAssertEqual(uplink.snapshot.queued, 5)
        XCTAssertEqual(uplink.snapshot.dropped, 0)
        let secondBurst = expectation(description: "next capture burst is sent intact")
        transport.observe { secondBurst.fulfill() }
        transport.completeFirst()
        wait(for: [secondBurst], timeout: 2)
        XCTAssertEqual(transport.batchSequences, [[0], [1, 2, 3, 4, 5], [6, 7, 8, 9, 10]])
        XCTAssertEqual(transport.headers.map(\.captureTimestampUs), (0...10).map { UInt64($0 * 20_000) })
        XCTAssertEqual(uplink.snapshot.dropped, 0)
        XCTAssertEqual(uplink.snapshot.queued, 0)
        transport.observe {}
        uplink.stop(sendEnd: false)
        transport.completeFirst()
    }

    func testFailedBatchCountsEveryDroppedFrameAndDoesNotRetryOldAudio() {
        let uplink = MicrophoneUplink()
        let transport = Transport()
        let pcm = Data(repeating: 0, count: 640)
        let seed = expectation(description: "seed write")
        transport.observe { seed.fulfill() }
        uplink.start(sessionId: 3, sendBatch: transport.send)
        uplink.offer(pcm: pcm, timestampUs: 0)
        wait(for: [seed], timeout: 2)
        for index in 1...5 { uplink.offer(pcm: pcm, timestampUs: UInt64(index * 20_000)) }
        let burst = expectation(description: "burst write")
        transport.observe { burst.fulfill() }
        transport.completeFirst()
        wait(for: [burst], timeout: 2)
        uplink.offer(pcm: pcm, timestampUs: 120_000)
        let fresh = expectation(description: "fresh audio after failed burst")
        transport.observe { fresh.fulfill() }
        transport.completeFirst(false)
        wait(for: [fresh], timeout: 2)
        XCTAssertEqual(uplink.snapshot.dropped, 5)
        XCTAssertEqual(transport.batchSequences, [[0], [1, 2, 3, 4, 5], [6]])
        XCTAssertEqual(uplink.snapshot.queued, 0)
        transport.observe {}
        uplink.stop(sendEnd: false)
        transport.completeFirst()
    }

    func testRetiredBatchCompletionCannotDrainOrFailTheReplacementSession() {
        let uplink = MicrophoneUplink()
        let transport = Transport()
        let pcm = Data(repeating: 0, count: 640)
        let old = expectation(description: "old session write")
        transport.observe { old.fulfill() }
        uplink.start(sessionId: 7, sendBatch: transport.send)
        uplink.offer(pcm: pcm, timestampUs: 0)
        wait(for: [old], timeout: 2)
        for index in 1...5 { uplink.offer(pcm: pcm, timestampUs: UInt64(index * 20_000)) }
        uplink.stop(sendEnd: false)
        let replacement = expectation(description: "replacement session write")
        transport.observe { replacement.fulfill() }
        uplink.start(sessionId: 8, sendBatch: transport.send)
        uplink.offer(pcm: pcm, timestampUs: 200_000)
        wait(for: [replacement], timeout: 2)
        for index in 1...5 { uplink.offer(pcm: pcm, timestampUs: UInt64(200_000 + index * 20_000)) }
        transport.completeFirst(false) // retired session's completion
        XCTAssertTrue(uplink.snapshot.inFlight)
        XCTAssertEqual(uplink.snapshot.queued, 5)
        XCTAssertEqual(uplink.snapshot.dropped, 0)
        XCTAssertEqual(transport.headers.map(\.sessionId), [7, 8])
        let next = expectation(description: "replacement burst")
        transport.observe { next.fulfill() }
        transport.completeFirst()
        wait(for: [next], timeout: 2)
        XCTAssertEqual(transport.headers.map(\.sessionId), [7] + [UInt32](repeating: 8, count: 6))
        XCTAssertEqual(transport.batchSequences, [[0], [0], [1, 2, 3, 4, 5]])
        XCTAssertEqual(uplink.snapshot.dropped, 0)
        transport.observe {}
        uplink.stop(sendEnd: false)
        transport.completeFirst()
    }

    func testStopOrdersOneEndAfterInFlightBatchAndDropsQueuedOldSpeech() {
        let uplink = MicrophoneUplink()
        let transport = Transport()
        let pcm = Data(repeating: 0, count: 640)
        let seed = expectation(description: "seed write")
        transport.observe { seed.fulfill() }
        uplink.start(sessionId: 7, sendBatch: transport.send)
        uplink.offer(pcm: pcm, timestampUs: 0)
        wait(for: [seed], timeout: 2)
        for index in 1...5 { uplink.offer(pcm: pcm, timestampUs: UInt64(index * 20_000)) }
        let burst = expectation(description: "old capture burst in flight")
        transport.observe { burst.fulfill() }
        transport.completeFirst()
        wait(for: [burst], timeout: 2)
        for index in 6...10 { uplink.offer(pcm: pcm, timestampUs: UInt64(index * 20_000)) }
        let end = expectation(description: "one ordered end packet")
        transport.observe { end.fulfill() }
        uplink.stop()
        wait(for: [end], timeout: 2)
        XCTAssertEqual(transport.batchSequences, [[0], [1, 2, 3, 4, 5], [11]])
        XCTAssertEqual(transport.headers.filter(\.isEnd).count, 1)
        XCTAssertTrue(transport.headers.last?.isEnd == true)
        XCTAssertEqual(uplink.snapshot.queued, 0)
        transport.observe {}
        transport.completeFirst(false) // old burst cannot restart its queue
        XCTAssertEqual(transport.headers.count, 7)
        XCTAssertFalse(uplink.snapshot.inFlight)
    }

    func testSameSessionToggleKeepsSequenceButNewSessionResets() {
        let uplink = MicrophoneUplink()
        let transport = Transport()
        let pcm = Data(repeating: 0, count: 640)
        let first = expectation(description: "first frame")
        transport.observe { first.fulfill() }
        uplink.start(sessionId: 22, sendBatch: transport.send)
        uplink.offer(pcm: pcm, timestampUs: 100)
        wait(for: [first], timeout: 2)
        let end = expectation(description: "end frame")
        transport.observe { end.fulfill() }
        uplink.stop()
        wait(for: [end], timeout: 2)
        let resumed = expectation(description: "resumed frame")
        transport.observe { resumed.fulfill() }
        uplink.start(sessionId: 22, sendBatch: transport.send)
        uplink.offer(pcm: pcm, timestampUs: 200)
        wait(for: [resumed], timeout: 2)
        XCTAssertEqual(transport.headers.map(\.microphoneSeq), [0, 1, 2])
        XCTAssertTrue(transport.headers[1].isEnd)
        transport.observe {}
        uplink.stop(sendEnd: false)
        let newSession = expectation(description: "new session frame")
        transport.observe { newSession.fulfill() }
        uplink.start(sessionId: 23, sendBatch: transport.send)
        uplink.offer(pcm: pcm, timestampUs: 300)
        wait(for: [newSession], timeout: 2)
        XCTAssertEqual(transport.headers.last?.microphoneSeq, 0)
        XCTAssertEqual(transport.headers.last?.sessionId, 23)
        transport.observe {}
        uplink.stop(sendEnd: false)
    }

    func testStoppedOrInvalidInputCannotEnqueueAndCongestionFailureIsOnlyDrop() {
        let uplink = MicrophoneUplink()
        let transport = Transport()
        uplink.offer(pcm: Data(repeating: 0, count: 640), timestampUs: 0)
        XCTAssertEqual(uplink.snapshot.queued, 0)
        let sent = expectation(description: "one valid frame")
        transport.observe { sent.fulfill() }
        uplink.start(sessionId: 3, sendBatch: transport.send)
        uplink.offer(pcm: Data([0]), timestampUs: 0)
        uplink.offer(pcm: Data(repeating: 0, count: 640), timestampUs: 0)
        wait(for: [sent], timeout: 2)
        transport.observe {}
        transport.completeFirst(false)
        XCTAssertEqual(uplink.snapshot.dropped, 1)
        uplink.stop(sendEnd: false)
        uplink.offer(pcm: Data(repeating: 0, count: 640), timestampUs: 20_000)
        XCTAssertEqual(uplink.snapshot.queued, 0)
    }
}
