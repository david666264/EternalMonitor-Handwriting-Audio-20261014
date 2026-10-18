import AVFoundation
import XCTest
@testable import EternalMonitor

final class AudioSessionCoordinatorTests: XCTestCase {
    private final class Hardware: DuplexAudioHardware {
        struct Plan { let playback: Bool; let microphone: Bool }
        var plans: [Plan] = []
        var shutdowns: [Bool] = []
        var rejectMicrophone = false
        func rebuild(playback: AudioPCMBuffer?, microphone: MicrophoneCaptureProcessor?) throws {
            plans.append(Plan(playback: playback != nil, microphone: microphone != nil))
            if rejectMicrophone, microphone != nil { throw MicrophoneAudioError.unavailable }
        }
        func shutdown(deactivate: Bool) { shutdowns.append(deactivate) }
    }

    private func processor() -> MicrophoneCaptureProcessor {
        MicrophoneCaptureProcessor(onPCM: { _, _ in }, onError: {})
    }

    func testPlaybackStartCannotReplaceDuplexAndMicStopLeavesPlaybackActive() throws {
        let hardware = Hardware()
        let coordinator = AudioSessionCoordinator(hardware: hardware)
        let mic = UUID(), playback = UUID()
        try coordinator.startMicrophone(token: mic, processor: processor())
        try coordinator.startPlayback(token: playback, pcm: AudioPCMBuffer())
        XCTAssertTrue(hardware.plans.last?.playback == true)
        XCTAssertTrue(hardware.plans.last?.microphone == true)
        coordinator.stopMicrophone(token: mic)
        XCTAssertTrue(hardware.plans.last?.playback == true)
        XCTAssertFalse(hardware.plans.last?.microphone == true)
        XCTAssertTrue(hardware.shutdowns.isEmpty, "Stopping input cannot deactivate a speaker lease")
        coordinator.stopPlayback(token: playback, deactivate: true)
        XCTAssertEqual(hardware.shutdowns, [true])
    }

    func testMutingPlaybackLeavesMicrophoneAndStalePlaybackTokenCannotCloseReplacement() throws {
        let hardware = Hardware()
        let coordinator = AudioSessionCoordinator(hardware: hardware)
        let mic = UUID(), first = UUID(), second = UUID()
        try coordinator.startPlayback(token: first, pcm: AudioPCMBuffer())
        try coordinator.startMicrophone(token: mic, processor: processor())
        try coordinator.startPlayback(token: second, pcm: AudioPCMBuffer())
        let count = hardware.plans.count
        coordinator.stopPlayback(token: first, deactivate: true)
        XCTAssertEqual(hardware.plans.count, count)
        XCTAssertTrue(hardware.shutdowns.isEmpty)
        coordinator.stopPlayback(token: second, deactivate: true)
        XCTAssertFalse(hardware.plans.last?.playback == true)
        XCTAssertTrue(hardware.plans.last?.microphone == true)
        XCTAssertTrue(hardware.shutdowns.isEmpty)
        coordinator.stopMicrophone(token: mic)
        XCTAssertEqual(hardware.shutdowns, [true])
    }

    func testAECFailureRestoresExistingPlaybackAndDoesNotEnableRawCapture() throws {
        let hardware = Hardware()
        let coordinator = AudioSessionCoordinator(hardware: hardware)
        try coordinator.startPlayback(token: UUID(), pcm: AudioPCMBuffer())
        hardware.rejectMicrophone = true
        XCTAssertThrowsError(try coordinator.startMicrophone(token: UUID(), processor: processor()))
        XCTAssertTrue(hardware.plans.last?.playback == true)
        XCTAssertFalse(hardware.plans.last?.microphone == true)
        XCTAssertTrue(hardware.shutdowns.isEmpty)
    }

    func testOutputRetainsMockableAPIAndFinalStopDeactivatesAfterRouteClose() throws {
        let hardware = Hardware()
        let output: AudioOutputDevice = AudioOutput(coordinator: AudioSessionCoordinator(hardware: hardware))
        try output.start(pcm: AudioPCMBuffer())
        output.stop(deactivate: false)
        output.stop(deactivate: true)
        XCTAssertEqual(hardware.shutdowns, [false, true])
    }

    func test48kFloatInputConvertsInto16kPCMFramesWithoutOpeningHardware() throws {
        let received = expectation(description: "converted PCM frame")
        received.assertForOverFulfill = false
        let processor = MicrophoneCaptureProcessor(onPCM: { data, _ in
            XCTAssertEqual(data.count, 640)
            received.fulfill()
        }, onError: { XCTFail("PCM conversion failed") })
        defer { processor.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        for index in 0..<3 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
            buffer.frameLength = 960
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<960 { samples[frame] = 0.2 * sin(Float(frame) * 0.1) }
            processor.offer(buffer, timestampUs: UInt64(index * 20_000))
        }
        wait(for: [received], timeout: 3)
    }
}
