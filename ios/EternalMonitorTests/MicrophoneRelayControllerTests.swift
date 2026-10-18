import Foundation
import XCTest
@testable import EternalMonitor

@MainActor
final class MicrophoneRelayControllerTests: XCTestCase {
    private final class Permission: MicrophonePermissionProviding {
        var permission: MicrophonePermission = .granted
        var requests = 0
        var completion: ((Bool) -> Void)?
        func request(_ completion: @escaping (Bool) -> Void) { requests += 1; self.completion = completion }
        func resolve(_ granted: Bool) { permission = granted ? .granted : .denied; completion?(granted) }
    }
    private final class Capture: MicrophoneCaptureDeviceProtocol {
        var starts = 0
        var stops = 0
        var pcm: ((Data, UInt64) -> Void)?
        var started: ((Result<Void, Error>) -> Void)?
        func start(onPCM: @escaping (Data, UInt64) -> Void, onError: @escaping () -> Void,
            completion: @escaping (Result<Void, Error>) -> Void) {
            starts += 1; pcm = onPCM; started = completion
        }
        func stop() { stops += 1; pcm = nil }
    }

    private func session(_ controller: MicrophoneRelayController, usb: Bool = true,
        capable: Bool = true, requested: Bool = true) {
        controller.configureSession(sessionId: 9, isUSB: usb,
            hostCaps: capable ? HelloAck.hostCapMicrophone : 0, requested: requested,
            sendBatch: { _, done in done(true) })
    }

    func testDefaultOffDoesNotPromptOrCaptureAndWiFiOrOldHostNeverOpensMic() {
        let capture = Capture(), permission = Permission()
        let controller = MicrophoneRelayController(capture: capture, permissions: permission, defaults: nil)
        session(controller)
        XCTAssertFalse(controller.enabled)
        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(permission.requests, 0)
        controller.setEnabled(true)
        XCTAssertEqual(capture.starts, 1)
        controller.stopSession()
        session(controller, usb: false)
        XCTAssertEqual(controller.status, .waitingUSB)
        XCTAssertEqual(capture.starts, 1)
        session(controller, capable: false)
        XCTAssertEqual(controller.status, .unsupported)
        XCTAssertEqual(capture.starts, 1)
        controller.stopSession()
    }

    func testFirstExplicitPermissionGrantRequestsExactlyOneReconnect() async {
        let capture = Capture(), permission = Permission()
        permission.permission = .undetermined
        let controller = MicrophoneRelayController(capture: capture, permissions: permission, defaults: nil)
        session(controller, requested: false)
        let reconnect = expectation(description: "reconnect after first grant")
        controller.onNeedsReconnect = { reconnect.fulfill() }
        controller.setEnabled(true)
        XCTAssertEqual(permission.requests, 1)
        XCTAssertEqual(controller.status, .requestingPermission)
        XCTAssertEqual(capture.starts, 0)
        permission.resolve(true)
        await fulfillment(of: [reconnect], timeout: 2)
        XCTAssertEqual(controller.status, .reconnectRequired)
        XCTAssertEqual(permission.requests, 1)
        session(controller, requested: true)
        XCTAssertEqual(capture.starts, 1)
        controller.stopSession()
    }

    func testDeniedPermissionAndLateGrantCannotStartAfterDisable() async {
        let capture = Capture(), permission = Permission()
        permission.permission = .denied
        let controller = MicrophoneRelayController(capture: capture, permissions: permission, defaults: nil)
        session(controller)
        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .denied)
        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(permission.requests, 0)
        controller.setEnabled(false)
        permission.permission = .undetermined
        controller.setEnabled(true)
        controller.setEnabled(false)
        permission.resolve(true)
        await Task.yield()
        XCTAssertEqual(controller.status, .off)
        XCTAssertEqual(capture.starts, 0)
    }

    func testBackgroundStopsCaptureAndStaleStartCannotMarkItRecording() async {
        let capture = Capture(), permission = Permission()
        let controller = MicrophoneRelayController(capture: capture, permissions: permission, defaults: nil)
        session(controller)
        controller.setEnabled(true)
        XCTAssertEqual(capture.starts, 1)
        controller.stopSession(backgrounded: true)
        capture.started?(.success(()))
        await Task.yield()
        XCTAssertEqual(controller.status, .waitingUSB)
        XCTAssertNil(capture.pcm)
        controller.setEnabled(true)
        XCTAssertEqual(capture.starts, 1, "Enabled preference is not background recording permission")
        controller.handleForeground()
        XCTAssertEqual(capture.starts, 1, "A fresh authorized USB session is required")
        session(controller)
        XCTAssertEqual(capture.starts, 2)
        controller.stopSession()
    }

    func testEngineStartWaitsForFirstPCMAndSilentFramesStillProveCaptureIsLive() async {
        let capture = Capture(), permission = Permission()
        var now: UInt64 = 10_000, clockReads = 0
        let confirmedStart = expectation(description: "engine start completion")
        let controller = MicrophoneRelayController(capture: capture, permissions: permission, defaults: nil, nowUs: {
            clockReads += 1
            if clockReads == 2 { confirmedStart.fulfill() }
            return now
        })
        session(controller)
        controller.setEnabled(true)
        capture.started?(.success(()))
        await fulfillment(of: [confirmedStart], timeout: 2)
        XCTAssertEqual(controller.status, .starting, "Engine.start alone cannot advertise live PCM")
        now += 1_000_000
        controller.refreshCaptureStatus()
        XCTAssertEqual(controller.status, .starting)
        capture.pcm?(Data(repeating: 0, count: 640), now)
        controller.refreshCaptureStatus()
        XCTAssertEqual(controller.status, .recording, "Real silence is PCM, and must not be mistaken for a dead tap")
        XCTAssertEqual(controller.inputLevel, 0)
        now += MicrophoneRelayController.pcmTimeoutUs
        controller.refreshCaptureStatus()
        XCTAssertEqual(controller.status, .noPCM)
        XCTAssertNil(capture.pcm)
        let starts = capture.starts
        now += MicrophoneRelayController.pcmTimeoutUs
        controller.refreshCaptureStatus()
        XCTAssertEqual(capture.starts, starts, "Capture loss must not cause an automatic restart loop")
        controller.stopSession()
    }

    func testNoInitialPCMHasBoundedFailureAndLateCompletionCannotReviveIt() async {
        let capture = Capture(), permission = Permission()
        var now: UInt64 = 0, clockReads = 0
        let confirmedStart = expectation(description: "engine start completion")
        let controller = MicrophoneRelayController(capture: capture, permissions: permission, defaults: nil, nowUs: {
            clockReads += 1
            if clockReads == 2 { confirmedStart.fulfill() }
            return now
        })
        session(controller)
        controller.setEnabled(true)
        capture.started?(.success(()))
        await fulfillment(of: [confirmedStart], timeout: 2)
        now = MicrophoneRelayController.pcmTimeoutUs
        controller.refreshCaptureStatus()
        XCTAssertEqual(controller.status, .noPCM)
        XCTAssertEqual(capture.starts, 1)
        XCTAssertNil(capture.pcm)
        capture.started?(.success(()))
        await Task.yield()
        XCTAssertEqual(controller.status, .noPCM, "A retired engine completion cannot reset the timeout")
        controller.stopSession()
    }

    func testOldCapturePCMCannotMarkReplacementSessionRecording() async {
        let capture = Capture(), permission = Permission()
        var clockReads = 0
        let firstStart = expectation(description: "first engine start")
        let secondStart = expectation(description: "replacement engine start")
        let controller = MicrophoneRelayController(capture: capture, permissions: permission, defaults: nil, nowUs: {
            clockReads += 1
            if clockReads == 2 { firstStart.fulfill() }
            if clockReads == 4 { secondStart.fulfill() }
            return 0
        })
        session(controller)
        controller.setEnabled(true)
        let retiredPCM = capture.pcm
        capture.started?(.success(()))
        await fulfillment(of: [firstStart], timeout: 2)
        session(controller)
        capture.started?(.success(()))
        await fulfillment(of: [secondStart], timeout: 2)
        retiredPCM?(Data(repeating: 1, count: 640), 0)
        controller.refreshCaptureStatus()
        XCTAssertEqual(controller.status, .starting)
        XCTAssertEqual(controller.inputLevel, 0)
        capture.pcm?(Data(repeating: 1, count: 640), 0)
        controller.refreshCaptureStatus()
        XCTAssertEqual(controller.status, .recording)
        XCTAssertGreaterThan(controller.inputLevel, 0)
        controller.stopSession()
    }
}
