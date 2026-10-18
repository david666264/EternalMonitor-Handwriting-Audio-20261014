import XCTest
@testable import EternalMonitor

final class ControlChannelInputBatchTests: XCTestCase {
    private final class Probe {
        let queue = DispatchQueue(label: "input-batch-test")
        var packets: [[Data]] = []
        var completions: [(Bool) -> Void] = []
        func send(_ packets: [Data], completion: @escaping (Bool) -> Void) {
            self.packets.append(packets)
            completions.append(completion)
        }
        func finishNext(_ success: Bool) {
            let next: ((Bool) -> Void)? = queue.sync {
                completions.isEmpty ? nil : completions.removeFirst()
            }
            guard let completion = next else { return XCTFail("Missing pending USB write") }
            completion(success)
            queue.sync {}
        }
    }

    private func connectedChannel(_ probe: Probe) throws -> ControlChannel {
        let helloSeen = expectation(description: "HELLO received")
        var hello: Hello2?
        let channel = ControlChannel(queue: probe.queue,
            batchTransport: { [weak probe] packets, completion in
                guard let probe else { completion(false); return }
                probe.send(packets, completion: completion)
            }) { data in
                if case .hello2(let value) = Wire.parseControl(data)?.message, hello == nil {
                    hello = value
                    helloSeen.fulfill()
                }
            }
        channel.startHandshake(listenPort: 50000, identity: ControlChannel.ClientIdentity(
            deviceName: "Test iPad", screenPxW: 640, screenPxH: 360,
            screenPtW: 640, screenPtH: 360, refreshHz: 60))
        wait(for: [helloSeen], timeout: 2)
        let nonce = try XCTUnwrap(hello).clientNonce
        probe.queue.sync {
            channel.handleControl(Wire.encodeControl(sessionId: 0, msgSeq: 1, message: .helloAck(HelloAck(
                status: .ok, acceptedVersion: 2, clientNonce: nonce, sessionId: 41,
                heartbeatIntervalMs: 1000, reportIntervalMs: 500, livenessTimeoutMs: 3000,
                streamConfig: StreamConfig(), hostName: "Test PC", authToken: Data(17...32),
                hostCaps: HelloAck.hostCapKeyboard | HelloAck.hostCapPen))))
        }
        return channel
    }

    func testLongInputWaitsForTransportAndPreservesFIFOAcrossJobs() throws {
        let probe = Probe()
        let channel = try connectedChannel(probe)
        defer { channel.stop(); probe.queue.sync {} }
        var keyboard = KeyboardRelayMachine()
        let text = keyboard.text(String(repeating: "中文😀\n", count: 100))
        let tail = keyboard.tap(0x28)
        var completions: [String] = []
        channel.sendInputs(text) { accepted in
            XCTAssertTrue(accepted)
            completions.append("text")
        }
        channel.sendInputs(tail) { accepted in
            XCTAssertTrue(accepted)
            completions.append("tail")
        }
        probe.queue.sync {
            XCTAssertEqual(probe.packets.count, 1, "No second batch before actual write completion")
            XCTAssertEqual(probe.packets.first?.count, ControlChannel.maximumInputBatchEvents)
            XCTAssertTrue(completions.isEmpty)
        }
        let textBatches = (text.count + ControlChannel.maximumInputBatchEvents - 1) / ControlChannel.maximumInputBatchEvents
        for _ in 0..<textBatches { probe.finishNext(true) }
        probe.queue.sync {
            XCTAssertEqual(completions, ["text"])
            XCTAssertEqual(probe.packets.count, textBatches + 1)
        }
        probe.finishNext(true)
        probe.queue.sync {
            XCTAssertEqual(completions, ["text", "tail"])
            XCTAssertTrue(probe.packets.allSatisfy { $0.count <= ControlChannel.maximumInputBatchEvents })
            let actual = probe.packets.flatMap { $0 }.compactMap { data -> WireInputEvent? in
                if case .inputEvent(let event) = Wire.parseControl(data)?.message { return event }
                return nil
            }
            XCTAssertEqual(actual, text + tail, "Chunking cannot lose, repeat, or reorder a Unicode unit")
        }
    }

    func testFailedWriteStopsRemainingChunksAndCompletesFailureOnce() throws {
        let probe = Probe()
        let channel = try connectedChannel(probe)
        defer { channel.stop(); probe.queue.sync {} }
        var keyboard = KeyboardRelayMachine()
        var results: [Bool] = []
        channel.sendInputs(keyboard.text(String(repeating: "长", count: 1000))) { results.append($0) }
        probe.queue.sync {}
        probe.finishNext(true)
        probe.finishNext(false)
        probe.queue.sync {
            XCTAssertEqual(results, [false])
            XCTAssertEqual(probe.packets.count, 2)
            XCTAssertTrue(probe.completions.isEmpty)
        }
    }

    func testStopRejectsInFlightTextAndIgnoresDelayedTransportCompletion() throws {
        let probe = Probe()
        let channel = try connectedChannel(probe)
        var keyboard = KeyboardRelayMachine()
        var results: [Bool] = []
        channel.sendInputs(keyboard.text(String(repeating: "保", count: 300))) { results.append($0) }
        probe.queue.sync {}
        channel.stop()
        probe.queue.sync { XCTAssertEqual(results, [false]) }
        probe.finishNext(true)
        probe.queue.sync {
            XCTAssertEqual(results, [false], "A stale callback cannot report success after disconnect")
            XCTAssertEqual(probe.packets.count, 1)
        }
    }

    func testOversizedQueuedInputIsRejectedBeforeTransport() throws {
        let probe = Probe()
        let channel = try connectedChannel(probe)
        defer { channel.stop(); probe.queue.sync {} }
        var keyboard = KeyboardRelayMachine()
        var results: [Bool] = []
        channel.sendInputs(keyboard.text(String(repeating: "大", count: ControlChannel.maximumQueuedInputEvents + 1))) {
            results.append($0)
        }
        probe.queue.sync {
            XCTAssertEqual(results, [false])
            XCTAssertTrue(probe.packets.isEmpty)
        }
    }

    func testDisconnectedInputReportsFailureInsteadOfSilentlyDropping() throws {
        let probe = Probe()
        let channel = try connectedChannel(probe)
        defer { channel.stop(); probe.queue.sync {} }
        // A nil session must fail its caller instead of silently erasing a draft.
        channel.stop()
        probe.queue.sync {}
        let failed = expectation(description: "Disconnected input reports failure")
        channel.sendInputs([WireInputEvent(kind: 5, phase: 0, buttons: 0, eventId: 1,
            xNorm: 0, yNorm: 0, keycode: 0x4e2d, clientTimeUs: 0)]) {
                XCTAssertFalse($0)
                failed.fulfill()
            }
        wait(for: [failed], timeout: 2)
    }
}
