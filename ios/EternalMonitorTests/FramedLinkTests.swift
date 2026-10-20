import Darwin
import Network
import XCTest
@testable import EternalMonitor

final class FramedLinkTests: XCTestCase {
    func testCaptureBurstAndEndPreserveEveryMicrophoneFrameOnUSB() throws {
        let server = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { Darwin.close(server) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindSize = size
        let port = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertEqual(Darwin.bind(server, $0, bindSize), 0)
                XCTAssertEqual(getsockname(server, $0, &size), 0)
            }
            return UInt16(bigEndian: pointer.pointee.sin_port)
        }
        XCTAssertEqual(listen(server, 1), 0)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        XCTAssertEqual(setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size)), 0)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let link = FramedLink(connection: connection)
        defer { link.stop() }
        let packets = try (0..<5).map { sequence in
            try XCTUnwrap(MicrophoneHeader(sessionId: 7, microphoneSeq: UInt32(sequence),
                captureTimestampUs: UInt64(sequence) * 20_000).encode(
                    pcm: Data(repeating: UInt8(sequence), count: MicrophoneHeader.payloadSize)))
        }
        let end = try XCTUnwrap(MicrophoneHeader(sessionId: 7, microphoneSeq: 5,
            captureTimestampUs: 100_000, isEnd: true).encode(pcm: Data()))
        let expected = try (packets + [end]).reduce(into: Data()) { $0.append(try EMLinkFramer.encode($1)) }
        let drained = expectation(description: "Five-frame capture burst and end accepted once")
        drained.assertForOverFulfill = true
        link.onError = { error in XCTFail("A valid microphone burst must not disconnect: \(error)") }
        link.onPreambleReady = { [weak link] in
            guard let link else { return }
            XCTAssertTrue(link.start(host: "127.0.0.1"))
            link.sendMicrophoneBatch(packets) { accepted in
                XCTAssertTrue(accepted)
                guard accepted else { drained.fulfill(); return }
                link.sendMicrophoneBatch([end]) { accepted in
                    XCTAssertTrue(accepted)
                    drained.fulfill()
                }
            }
        }
        link.validatePreamble()
        let peer = accept(server, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        guard peer >= 0 else { return }
        defer { Darwin.close(peer) }
        XCTAssertEqual(setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size)), 0)
        let preambleCount = EMLinkFramer.preamble.withUnsafeBytes { Darwin.send(peer, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(preambleCount, EMLinkFramer.preamble.count)
        var actual = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while actual.count < expected.count {
            let count = recv(peer, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            actual.append(contentsOf: buffer.prefix(count))
        }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(actual, expected, "Every microphone frame and the final end marker must arrive once, in order")
    }

    func testInvalidMicrophoneBatchesFailOnceWithoutClosingUSB() throws {
        let link = FramedLink(connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
        defer { link.onClosed = nil; link.stop() }
        let packet = try XCTUnwrap(MicrophoneHeader(sessionId: 7, microphoneSeq: 0,
            captureTimestampUs: 0).encode(pcm: Data(repeating: 0, count: MicrophoneHeader.payloadSize)))
        let end = try XCTUnwrap(MicrophoneHeader(sessionId: 7, microphoneSeq: 1,
            captureTimestampUs: 20_000, isEnd: true).encode(pcm: Data()))
        let control = Wire.encodeControl(sessionId: 7, msgSeq: 1, message: .ping(WirePing(t1Us: 42)))
        let invalid = [[], Array(repeating: packet, count: MicrophoneUplink.maximumQueuedFrames + 1),
                       [Data([1])], [packet, end], [control]]
        let rejected = expectation(description: "Malformed, excessive and mixed batches rejected once each")
        rejected.expectedFulfillmentCount = invalid.count
        rejected.assertForOverFulfill = true
        link.onClosed = { XCTFail("Rejected live microphone batches must not close the USB link") }
        for batch in invalid {
            link.sendMicrophoneBatch(batch) { accepted in
                XCTAssertFalse(accepted)
                rejected.fulfill()
            }
        }
        wait(for: [rejected], timeout: 3)
    }

    func testLongTextBurstExceedsOld64PacketLimitWithoutClosingUSB() throws {
        let server = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { Darwin.close(server) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindSize = size
        let port = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertEqual(Darwin.bind(server, $0, bindSize), 0)
                XCTAssertEqual(getsockname(server, $0, &size), 0)
            }
            return UInt16(bigEndian: pointer.pointee.sin_port)
        }
        XCTAssertEqual(listen(server, 1), 0)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        XCTAssertEqual(setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size)), 0)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let link = FramedLink(connection: connection)
        defer { link.stop() }
        var keyboard = KeyboardRelayMachine()
        let events = keyboard.text(String(repeating: "长文😀\n", count: 256))
        let packets = events.enumerated().map { index, event in
            Wire.encodeControl(sessionId: 7, msgSeq: UInt32(index + 1), message: .inputEvent(event))
        }
        XCTAssertGreaterThan(packets.count, 1000)
        let marker = Wire.encodeControl(sessionId: 7, msgSeq: UInt32(packets.count + 1), message: .ping(WirePing(t1Us: 42)))
        let expected = try (packets + [marker]).reduce(into: Data()) { $0.append(try EMLinkFramer.encode($1)) }
        XCTAssertLessThan(expected.count, FramedLink.maximumPendingBytes)
        let drained = expectation(description: "Long burst accepted without tearing down USB")
        link.onError = { error in XCTFail("A valid text burst must not disconnect: \(error)") }
        link.onPreambleReady = { [weak link] in
            guard let link else { return }
            XCTAssertTrue(link.start(host: "127.0.0.1"))
            // The old implementation synchronously failed on event 66 here,
            // before NWConnection's completion could run on the same queue.
            for packet in packets { link.send(packet) }
            link.sendBatch([marker]) { accepted in
                XCTAssertTrue(accepted)
                drained.fulfill()
            }
        }
        link.validatePreamble()
        let peer = accept(server, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        guard peer >= 0 else { return }
        defer { Darwin.close(peer) }
        XCTAssertEqual(setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size)), 0)
        let count = EMLinkFramer.preamble.withUnsafeBytes { Darwin.send(peer, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(count, EMLinkFramer.preamble.count)
        var actual = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while actual.count < expected.count {
            let count = recv(peer, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            actual.append(contentsOf: buffer.prefix(count))
        }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(actual, expected, "Every UTF-16 unit and Enter edge must arrive once, in order")
    }

    func testOversizedUSBInputBatchFailsExplicitlyAndCompletesOnce() {
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let link = FramedLink(connection: connection)
        defer { link.stop() }
        let rejected = expectation(description: "Bounded byte buffer rejects overload")
        rejected.assertForOverFulfill = true
        let closed = expectation(description: "Overload closes the unsafe input session")
        link.onClosed = { closed.fulfill() }
        link.sendBatch(Array(repeating: Data(repeating: 1, count: EMLinkFramer.maximumLength), count: 200)) { accepted in
            XCTAssertFalse(accepted)
            rejected.fulfill()
        }
        wait(for: [rejected, closed], timeout: 2)
    }

    func testStopFlushesQueuedControlsAndGoodbyeInOrder() throws {
        let server = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { Darwin.close(server) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindSize = size
        let port = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertEqual(Darwin.bind(server, $0, bindSize), 0)
                XCTAssertEqual(getsockname(server, $0, &size), 0)
            }
            return UInt16(bigEndian: pointer.pointee.sin_port)
        }
        XCTAssertEqual(listen(server, 1), 0)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        XCTAssertEqual(setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size)), 0)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let link = FramedLink(connection: connection)
        defer { link.stop() }
        var packets = (1...16).map { sequence in
            Wire.encodeControl(sessionId: 7, msgSeq: UInt32(sequence), message: .ping(WirePing(t1Us: 42)))
        }
        packets.append(Wire.encodeControl(sessionId: 7, msgSeq: 17, message: .bye(.appBackground)))
        let expected = try packets.reduce(into: Data()) { $0.append(try EMLinkFramer.encode($1)) }
        let stopped = expectation(description: "Controls queued and link stopped")
        link.onPreambleReady = { [weak link] in
            guard let link else { return }
            XCTAssertTrue(link.start(host: "127.0.0.1"))
            for packet in packets { link.send(packet) }
            link.stop()
            stopped.fulfill()
        }
        link.validatePreamble()
        let peer = accept(server, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        guard peer >= 0 else { return }
        defer { Darwin.close(peer) }
        XCTAssertEqual(setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size)), 0)
        let count = EMLinkFramer.preamble.withUnsafeBytes { Darwin.send(peer, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(count, EMLinkFramer.preamble.count)
        wait(for: [stopped], timeout: 3)
        var actual = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while actual.count < expected.count {
            let count = recv(peer, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            actual.append(contentsOf: buffer.prefix(count))
        }
        XCTAssertEqual(actual, expected, "Stop must deliver all queued controls before the final BYE")
    }
}
