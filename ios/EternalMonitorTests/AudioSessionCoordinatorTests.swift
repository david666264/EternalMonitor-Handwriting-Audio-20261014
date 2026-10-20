import AVFoundation
import XCTest
@testable import EternalMonitor

final class AudioSessionCoordinatorTests: XCTestCase {
    private final class Hardware: DuplexAudioHardware {
        struct Plan { let playback: Bool; let microphone: Bool }
        var plans: [Plan] = []
        var shutdowns: [Bool] = []
        var rejectMicrophone = false
        var rejectPlaybackOnly = false
        var rejectMicrophoneOnly = false
        var onConfigurationChange: ((ObjectIdentifier) -> Void)?
        var engineIdentity = NSObject()
        var running = true
        var allowsPlaybackReplacement = false
        var playbackReplacements = 0
        var replacedPCM: AudioPCMBuffer?
        func requiresRebuild(afterConfigurationChange identity: ObjectIdentifier) -> Bool {
            identity == ObjectIdentifier(engineIdentity) && !running
        }
        func replacePlaybackWhileMicrophoneRuns(_ playback: AudioPCMBuffer?) -> Bool {
            guard allowsPlaybackReplacement, running, plans.last?.microphone == true else { return false }
            playbackReplacements += 1
            replacedPCM = playback
            return true
        }
        func rebuild(playback: AudioPCMBuffer?, microphone: MicrophoneCaptureProcessor?) throws {
            plans.append(Plan(playback: playback != nil, microphone: microphone != nil))
            if rejectMicrophone, microphone != nil { throw MicrophoneAudioError.unavailable }
            if rejectPlaybackOnly, playback != nil, microphone == nil { throw MicrophoneAudioError.unavailable }
            if rejectMicrophoneOnly, microphone != nil, playback == nil { throw MicrophoneAudioError.unavailable }
            engineIdentity = NSObject()
            running = true
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
        XCTAssertGreaterThan(processor.snapshot.tapBuffers, 0)
        XCTAssertGreaterThan(processor.snapshot.convertedBuffers, 0)
        XCTAssertGreaterThan(processor.snapshot.emittedFrames, 0)
    }

    func testStoppingMicReportsADeadRemainingPlaybackGraphThroughOutputAdapter() throws {
        let hardware = Hardware()
        let coordinator = AudioSessionCoordinator(hardware: hardware)
        let output: AudioOutputDevice = AudioOutput(coordinator: coordinator)
        var failures = 0
        output.setGraphFailureHandler { _ in failures += 1 }
        try output.start(pcm: AudioPCMBuffer())
        let mic = UUID()
        try coordinator.startMicrophone(token: mic, processor: processor())
        hardware.rejectPlaybackOnly = true
        coordinator.stopMicrophone(token: mic)
        XCTAssertEqual(failures, 1, "A failed playback rebuild must reach the player's failure handler")
        XCTAssertEqual(hardware.shutdowns, [true])
        output.stop(deactivate: true)
    }

    func testOutputFailureHandlerIsCapturedByTheLeaseThatStartedIt() throws {
        let hardware = Hardware()
        let coordinator = AudioSessionCoordinator(hardware: hardware)
        let output = AudioOutput(coordinator: coordinator)
        var firstFailures = 0, replacementFailures = 0
        output.setGraphFailureHandler { _ in firstFailures += 1 }
        try output.start(pcm: AudioPCMBuffer())
        // Preparing a future generation's callback must not change ownership
        // of the graph that is currently running.
        output.setGraphFailureHandler { _ in replacementFailures += 1 }
        let mic = UUID()
        try coordinator.startMicrophone(token: mic, processor: processor())
        hardware.rejectPlaybackOnly = true
        coordinator.stopMicrophone(token: mic)
        XCTAssertEqual(firstFailures, 1)
        XCTAssertEqual(replacementFailures, 0, "An old graph cannot deliver into a newly installed handler")
        output.stop(deactivate: true)
        hardware.rejectPlaybackOnly = false
        try output.start(pcm: AudioPCMBuffer())
        let nextMic = UUID()
        try coordinator.startMicrophone(token: nextMic, processor: processor())
        hardware.rejectPlaybackOnly = true
        coordinator.stopMicrophone(token: nextMic)
        XCTAssertEqual(firstFailures, 1)
        XCTAssertEqual(replacementFailures, 1, "The next start captures the replacement handler")
        output.stop(deactivate: true)
    }

    func testStoppingPlaybackReportsADeadRemainingCaptureGraphOnlyOnce() throws {
        let hardware = Hardware()
        let coordinator = AudioSessionCoordinator(hardware: hardware)
        let playback = UUID(), mic = UUID()
        var failures = 0
        let processor = MicrophoneCaptureProcessor(onPCM: { _, _ in }, onError: { failures += 1 })
        try coordinator.startPlayback(token: playback, pcm: AudioPCMBuffer())
        try coordinator.startMicrophone(token: mic, processor: processor)
        hardware.rejectMicrophoneOnly = true
        coordinator.stopPlayback(token: playback, deactivate: true)
        XCTAssertEqual(failures, 1, "Capture must stop advertising a working source after its graph failed")
        XCTAssertEqual(hardware.shutdowns, [true])
        processor.fail()
        XCTAssertEqual(failures, 1, "Repeated failure delivery cannot create a restart/error loop")
        coordinator.stopMicrophone(token: mic)
        processor.stop()
    }

    func testOnlyCurrentStoppedEngineConfigurationChangeRebuildsBothLeases() throws {
        let hardware = Hardware()
        let coordinator = AudioSessionCoordinator(hardware: hardware)
        let mic = UUID(), playback = UUID()
        try coordinator.startPlayback(token: playback, pcm: AudioPCMBuffer())
        try coordinator.startMicrophone(token: mic, processor: processor())
        let initialPlans = hardware.plans.count
        let oldEngine = hardware.engineIdentity
        hardware.onConfigurationChange?(ObjectIdentifier(oldEngine))
        coordinator.flushPendingHardwareChanges()
        XCTAssertEqual(hardware.plans.count, initialPlans, "A notification alone cannot restart a running graph")
        hardware.running = false
        hardware.onConfigurationChange?(ObjectIdentifier(oldEngine))
        coordinator.flushPendingHardwareChanges()
        XCTAssertEqual(hardware.plans.count, initialPlans + 1)
        XCTAssertTrue(hardware.plans.last?.playback == true)
        XCTAssertTrue(hardware.plans.last?.microphone == true)
        hardware.onConfigurationChange?(ObjectIdentifier(oldEngine))
        coordinator.flushPendingHardwareChanges()
        XCTAssertEqual(hardware.plans.count, initialPlans + 1, "Late notifications from a retired engine are ignored")
        coordinator.stopMicrophone(token: mic)
        coordinator.stopPlayback(token: playback, deactivate: true)
        hardware.running = false
        hardware.onConfigurationChange?(ObjectIdentifier(hardware.engineIdentity))
        coordinator.flushPendingHardwareChanges()
        XCTAssertEqual(hardware.plans.count, initialPlans + 2, "No leases means no automatic graph recreation")
    }

    func testConfigurationRecoveryFailureReachesBothExistingConsumers() throws {
        let hardware = Hardware()
        let coordinator = AudioSessionCoordinator(hardware: hardware)
        var outputFailures = 0, inputFailures = 0
        try coordinator.startPlayback(token: UUID(), pcm: AudioPCMBuffer(), onFailure: { _ in outputFailures += 1 })
        let input = MicrophoneCaptureProcessor(onPCM: { _, _ in }, onError: { inputFailures += 1 })
        try coordinator.startMicrophone(token: UUID(), processor: input)
        hardware.rejectMicrophone = true
        hardware.running = false
        hardware.onConfigurationChange?(ObjectIdentifier(hardware.engineIdentity))
        coordinator.flushPendingHardwareChanges()
        XCTAssertEqual(outputFailures, 1)
        XCTAssertEqual(inputFailures, 1)
        XCTAssertEqual(hardware.shutdowns, [true])
        input.stop()
    }

    func testPlaybackLeaseStartReplacementAndStopPreserveRunningMicrophoneGraph() throws {
        let hardware = Hardware()
        hardware.allowsPlaybackReplacement = true
        let coordinator = AudioSessionCoordinator(hardware: hardware)
        let mic = UUID(), first = UUID(), second = UUID()
        let firstPCM = AudioPCMBuffer(), secondPCM = AudioPCMBuffer()
        try coordinator.startMicrophone(token: mic, processor: processor())
        let microphoneEngine = hardware.engineIdentity
        try coordinator.startPlayback(token: first, pcm: firstPCM)
        try coordinator.startPlayback(token: second, pcm: secondPCM)
        XCTAssertEqual(hardware.plans.count, 1, "Joining PC audio must not recreate VoiceProcessing IO")
        XCTAssertTrue(hardware.engineIdentity === microphoneEngine)
        XCTAssertTrue(hardware.replacedPCM === secondPCM)
        let replacements = hardware.playbackReplacements
        coordinator.stopPlayback(token: first, deactivate: true)
        XCTAssertEqual(hardware.playbackReplacements, replacements, "A retired speaker token cannot mute its replacement")
        coordinator.stopPlayback(token: second, deactivate: true)
        XCTAssertNil(hardware.replacedPCM)
        XCTAssertEqual(hardware.plans.count, 1, "Muting PC audio must keep microphone input alive")
        XCTAssertTrue(hardware.shutdowns.isEmpty)
        coordinator.stopMicrophone(token: mic)
        XCTAssertEqual(hardware.shutdowns, [true], "Explicit mic-off with no speaker lease still releases recording")
    }

    func testStoppedMicrophoneGraphCannotUsePlaybackSlotShortcut() throws {
        let hardware = Hardware()
        hardware.allowsPlaybackReplacement = true
        let coordinator = AudioSessionCoordinator(hardware: hardware)
        let mic = UUID(), playback = UUID()
        try coordinator.startMicrophone(token: mic, processor: processor())
        hardware.running = false
        try coordinator.startPlayback(token: playback, pcm: AudioPCMBuffer())
        XCTAssertEqual(hardware.playbackReplacements, 0)
        XCTAssertEqual(hardware.plans.count, 2, "A stopped graph needs real hardware recovery")
        XCTAssertTrue(hardware.plans.last?.microphone == true)
        XCTAssertTrue(hardware.plans.last?.playback == true)
        coordinator.stopPlayback(token: playback, deactivate: false)
        coordinator.stopMicrophone(token: mic)
    }

    func testConfigurationNotificationDoesNotRetainRetiredEngineWhileReplacementStarts() throws {
        let hardware = Hardware()
        let coordinator = AudioSessionCoordinator(hardware: hardware)
        let mic = UUID()
        try coordinator.startMicrophone(token: mic, processor: processor())
        weak var retiredEngine: NSObject? = hardware.engineIdentity
        let identity = ObjectIdentifier(hardware.engineIdentity)
        hardware.running = false
        hardware.onConfigurationChange?(identity)
        coordinator.flushPendingHardwareChanges()
        XCTAssertNil(retiredEngine, "The queued identity must not keep an old VoiceProcessing engine alive")
        coordinator.stopMicrophone(token: mic)
    }
}

final class AudioPlaybackSlotTests: XCTestCase {
    func testReplacingAndClearingPlaybackRendersOnlyCurrentStereoPCM() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        buffer.frameLength = 960
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let slot = AudioPlaybackSlot()
        XCTAssertFalse(slot.render(frames: 960, buffers: buffers, nowUs: 0))
        XCTAssertEqual(channels[0][0], 0)
        var first: AudioPCMBuffer? = AudioPCMBuffer()
        let second = AudioPCMBuffer()
        weak var retiredPCM: AudioPCMBuffer? = first
        for _ in 0..<3 {
            first?.append([Float](repeating: 0.1, count: 1920))
            second.append([Float](repeating: 0.2, count: 1920))
        }
        slot.replace(first)
        XCTAssertTrue(slot.render(frames: 960, buffers: buffers, nowUs: 20_000))
        XCTAssertEqual(channels[0][0], 0.1)
        XCTAssertEqual(channels[1][959], 0.1)
        slot.replace(second)
        first = nil
        XCTAssertNil(retiredPCM, "The source slot cannot retain old audio after a lease replacement")
        XCTAssertTrue(slot.render(frames: 960, buffers: buffers, nowUs: 40_000))
        XCTAssertEqual(channels[0][0], 0.2)
        XCTAssertEqual(channels[1][959], 0.2)
        slot.replace(nil)
        XCTAssertFalse(slot.render(frames: 960, buffers: buffers, nowUs: 60_000))
        for channel in 0..<2 {
            XCTAssertTrue((0..<960).allSatisfy { channels[channel][$0] == 0 }, "Muted output must contain no old PCM")
        }
    }
}
