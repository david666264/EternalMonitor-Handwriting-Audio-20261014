import Foundation
import XCTest
@testable import EternalMonitor

final class MicrophoneUplinkTests: XCTestCase {
    private final class Transport {
        let lock = NSLock()
        var packets: [Data] = []
        var completions: [(Bool) -> Void] = []
        var onSend: (() -> Void)?
        func send(_ packets: [Data], done: @escaping (Bool) -> Void) {
            lock.lock()
            self.packets.append(contentsOf: packets)
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
    }

    func testSlowTransportRetainsOnlyNewestThreeFramesAndOneInFlight() {
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
        XCTAssertEqual(uplink.snapshot.queued, 3)
        XCTAssertTrue(uplink.snapshot.inFlight)
        XCTAssertEqual(uplink.snapshot.dropped, 97)
        let second = expectation(description: "freshest remaining send")
        transport.observe { second.fulfill() }
        transport.completeFirst()
        wait(for: [second], timeout: 2)
        XCTAssertEqual(transport.headers.map(\.microphoneSeq), [0, 98])
        transport.observe {}
        uplink.stop(sendEnd: false)
        transport.completeFirst()
        XCTAssertEqual(uplink.snapshot.queued, 0)
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
