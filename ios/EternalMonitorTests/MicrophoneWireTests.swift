import Foundation
import XCTest
@testable import EternalMonitor

final class MicrophoneWireTests: XCTestCase {
    func testExactLittleEndianHeaderAndPCMFrameRoundTrip() throws {
        let header = MicrophoneHeader(sessionId: 0x12345678, microphoneSeq: 0x90abcdef, captureTimestampUs: 0x0102030405060708)
        let pcm = Data(repeating: 0x7f, count: 640)
        let encoded = try XCTUnwrap(header.encode(pcm: pcm))
        XCTAssertEqual(encoded.count, 664)
        XCTAssertEqual(Array(encoded.prefix(24)), [0x45, 0x4d, 2, 4, 0, 0, 0x80, 2,
            0x78, 0x56, 0x34, 0x12, 0xef, 0xcd, 0xab, 0x90, 8, 7, 6, 5, 4, 3, 2, 1])
        let decoded = try XCTUnwrap(MicrophoneHeader.decode(encoded))
        XCTAssertEqual(decoded.header, header)
        XCTAssertEqual(encoded.subdata(in: decoded.payloadRange), pcm)
        XCTAssertEqual(Wire.classify(encoded), .microphone(flags: 0))
        XCTAssertNil(Wire.parseControl(encoded))
    }

    func testEndIsEmptyAndStrictFlagsLengthsAndSessionsAreEnforced() throws {
        let header = MicrophoneHeader(sessionId: 7, microphoneSeq: 9, captureTimestampUs: 10, isEnd: true)
        let end = try XCTUnwrap(header.encode(pcm: Data()))
        XCTAssertEqual(end.count, 24)
        XCTAssertEqual(MicrophoneHeader.decode(end)?.header, header)
        XCTAssertEqual(Wire.classify(end), .microphone(flags: 1))
        XCTAssertNil(header.encode(pcm: Data(repeating: 0, count: 640)))
        XCTAssertNil(MicrophoneHeader(sessionId: 0, microphoneSeq: 0, captureTimestampUs: 0).encode(pcm: Data(repeating: 0, count: 640)))
        let frame = try XCTUnwrap(MicrophoneHeader(sessionId: 1, microphoneSeq: 0, captureTimestampUs: 0).encode(pcm: Data(repeating: 0, count: 640)))
        for (index, value) in [(4, UInt8(2)), (5, UInt8(1)), (6, UInt8(0)), (8, UInt8(0))] {
            var invalid = frame
            invalid[index] = value
            XCTAssertNil(MicrophoneHeader.decode(invalid))
        }
        XCTAssertNil(MicrophoneHeader.decode(Data(frame.dropLast())))
        XCTAssertNil(MicrophoneHeader.decode(frame + Data([0])))
        XCTAssertEqual(Hello2.featureWantsMicrophone, 1 << 3)
        XCTAssertEqual(HelloAck.hostCapMicrophone, 1 << 5)
    }

    func testMicrophoneUplinkIsNeverPlayedAsInboundAudio() throws {
        let datagrams = MediaDatagrams()
        datagrams.setAcceptedSessionId(2)
        var audioCount = 0
        var controlCount = 0
        datagrams.onAudioPacket = { _, _ in audioCount += 1 }
        datagrams.onControlDatagram = { _ in controlCount += 1 }
        datagrams.handle(try XCTUnwrap(MicrophoneHeader(sessionId: 2, microphoneSeq: 0, captureTimestampUs: 0)
            .encode(pcm: Data(repeating: 0, count: 640))))
        XCTAssertEqual(audioCount, 0)
        XCTAssertEqual(controlCount, 0)
        XCTAssertEqual(datagrams.legacyLookingDatagrams, 0)
    }

    func testVariableConverterOutputFormsOnlyWhole20msFrames() {
        var accumulator = MicrophoneFrameAccumulator()
        var frames: [(Data, UInt64)] = []
        accumulator.append(pcm: Data(repeating: 1, count: 200), captureTimestampUs: 1_000) { frames.append(($0, $1)) }
        XCTAssertTrue(frames.isEmpty)
        accumulator.append(pcm: Data(repeating: 2, count: 1080), captureTimestampUs: 7_250) { frames.append(($0, $1)) }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.map { $0.0.count }, [640, 640])
        XCTAssertEqual(frames.map { $0.1 }, [1_000, 21_000])
        XCTAssertEqual(frames[0].0.prefix(200), Data(repeating: 1, count: 200))
        XCTAssertEqual(frames[1].0, Data(repeating: 2, count: 640))
    }

    func testCaptureGapDropsPartialOldSpeechAndOddPCMIsRejected() {
        var accumulator = MicrophoneFrameAccumulator()
        var frames: [(Data, UInt64)] = []
        accumulator.append(pcm: Data(repeating: 1, count: 200), captureTimestampUs: 1_000) { frames.append(($0, $1)) }
        accumulator.append(pcm: Data([0]), captureTimestampUs: 2_000) { frames.append(($0, $1)) }
        accumulator.append(pcm: Data(repeating: 2, count: 640), captureTimestampUs: 200_000) { frames.append(($0, $1)) }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].0, Data(repeating: 2, count: 640))
        XCTAssertEqual(frames[0].1, 200_000)
    }
}
