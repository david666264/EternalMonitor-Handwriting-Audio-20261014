import XCTest

final class StreamLifecycleTests: XCTestCase {
    private var hostLog: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["EM_INPUT_HOST_LOG"]!)
    }

    private func launch(audioEnabled: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-didSeeOnboarding", "YES", "-allowUSB", "NO", "-controlPC", "NO",
            "-playPCaudio", audioEnabled ? "YES" : "NO", "-autoReconnect", "YES", "-autoResumeOnForeground", "YES", "-targetFPS", "60"]
        app.launchEnvironment["EM_AUTOCONNECT"] = ProcessInfo.processInfo.environment["EM_INPUT_HOST"] ?? "127.0.0.1:19875"
        app.launchEnvironment["EM_E2E_LOG"] = "1"
        app.launch()
        waitForSignal("正在传输", app: app, timeout: 15)
        return app
    }

    func testHostRestart() throws {
        let directory = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["EM_LIFECYCLE_DIR"]))
        let before = readHostLog().count
        let app = launch()
        // Wait for multiple reports so the liveness test starts after a real heartbeat.
        expectation(for: NSPredicate { _, _ in
            self.readHostLog().dropFirst(before).components(separatedBy: "Receiver report").count >= 3
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        let started = ProcessInfo.processInfo.systemUptime
        try Data().write(to: directory.appendingPathComponent("stop.request"))
        waitForSignal("信号中断，正在重连", app: app, timeout: 7)
        capture("signal-lost", app: app)
        try Data().write(to: directory.appendingPathComponent("start.request"))
        waitForSignal("正在传输", app: app, timeout: 15)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(elapsed, 15, "Host restart must recover within fifteen seconds")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("restarted.json").path))
        print("E2E_LIFECYCLE_RESUMED elapsed=\(elapsed)")
        capture("stream-resumed", app: app)
        disconnect(app)
    }

    func testBackgroundResume() {
        assertBackgroundResume(audioEnabled: false)
    }

    // Simulator automation cannot invoke a real system dictation session.
    // This covers the foreground recovery boundary with a real audio stream;
    // interruption begin/end ordering is covered by AudioPlaybackTests.
    func testBackgroundResumeWithAudio() {
        assertBackgroundResume(audioEnabled: true)
    }

    private func assertBackgroundResume(audioEnabled: Bool) {
        let app = launch(audioEnabled: audioEnabled)
        if audioEnabled {
            waitForAudioPlaying(app)
            capture("audio-before-background", app: app)
        }
        let before = readHostLog().count
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        expectation(for: NSPredicate { _, _ in
            self.readHostLog().dropFirst(before).contains("AppBackground")
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        print("E2E_LIFECYCLE_BACKGROUND bye=AppBackground")
        let started = ProcessInfo.processInfo.systemUptime
        app.activate()
        waitForSignal("正在传输", app: app, timeout: 15)
        if audioEnabled { waitForAudioPlaying(app) }
        print("E2E_LIFECYCLE_FOREGROUND elapsed=\(ProcessInfo.processInfo.systemUptime - started)")
        capture(audioEnabled ? "audio-background-resumed" : "background-resumed", app: app)
        disconnect(app)
    }

    private func waitForAudioPlaying(_ app: XCUIApplication) {
        let hud = app.buttons["display.hud"]
        let matches = NSPredicate(format: "exists == true AND label CONTAINS %@", "正在播放电脑声音")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            // Controls fade while the connection is recovering. Input relay
            // is off in this test, so tapping the picture only reveals them.
            if !hud.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            let check = XCTNSPredicateExpectation(predicate: matches, object: hud)
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            if XCTWaiter().wait(for: [check], timeout: min(2, remaining)) == .completed { return }
        }
        XCTFail("Live computer audio did not resume")
    }

    private func readHostLog() -> String { (try? String(contentsOf: hostLog, encoding: .utf8)) ?? "" }

    private func waitForSignal(_ label: String, app: XCUIApplication, timeout: TimeInterval) {
        let signal = app.descendants(matching: .any)["display.signal"].firstMatch
        expectation(for: NSPredicate(format: "exists == true AND label == %@", label), evaluatedWith: signal)
        waitForExpectations(timeout: timeout)
    }

    private func disconnect(_ app: XCUIApplication) {
        if !app.buttons["display.disconnect"].exists { app.tap() }
        app.buttons["display.disconnect"].tap()
        XCTAssertTrue(app.textFields["connect.host"].waitForExistence(timeout: 5))
        app.terminate()
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
