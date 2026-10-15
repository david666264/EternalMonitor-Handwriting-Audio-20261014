import Network
import XCTest

/// The fixture changes cable availability; all handshake and video traffic
/// comes from the real synthetic host started by scripts/test_ios.sh.
final class USBStreamTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        cable("STOP")
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        cable("STOP")
    }

    func testUSBAutoconnectAndManualDisconnect() {
        let app = launchApp()
        XCTAssertTrue(app.textFields["connect.host"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["connect.usbStatus"].exists)
        cable("START")
        assertTransport("USB", app: app)
        capture("usb-connected", app: app)
        app.buttons["display.disconnect"].tap()
        XCTAssertTrue(app.textFields["connect.host"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connect.usb"].exists)
        XCTAssertTrue(app.staticTexts["connect.usbStatus"].label.contains("已断开"))
        capture("usb-disconnected", app: app)
    }

    func testUSBTakesOverWiFiAndUnplugFallsBack() {
        let app = launchApp(autoconnect: "127.0.0.1:19877")
        assertTransport("WiFi", app: app)
        cable("START")
        assertTransport("USB", app: app)
        capture("usb-takeover", app: app)
        cable("STOP")
        assertTransport("WiFi", app: app, timeout: 5)
        capture("usb-unplug-wifi", app: app)
        cable("START")
        assertTransport("USB", app: app)
        capture("usb-replug", app: app)
    }

    func testUSBDrawingModePlaysAudioAndAllowsLiveMute() {
        let app = launchApp(drawingMode: true, audioEnabled: true)
        XCTAssertTrue(app.textFields["connect.host"].waitForExistence(timeout: 10))
        cable("START")
        assertTransport("USB", app: app)
        XCTAssertTrue(app.buttons["display.drawingControls"].exists)
        assertAudio("正在播放电脑声音", app: app)
        capture("usb-drawing-audio-playing", app: app)

        showDrawingControls(app, showing: app.buttons["display.settings"])
        app.buttons["display.settings"].tap()
        let toggle = app.switches["settings.playPCaudio"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).press(forDuration: 0.15)
        let muted = NSPredicate(format: "value == %@", "0")
        expectation(for: muted, evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        app.buttons["settings.done"].tap()
        assertTransport("USB", app: app)
        assertAudio("电脑声音已静音或不可用", app: app)
        XCTAssertTrue(app.buttons["display.drawingControls"].exists)
        XCTAssertFalse(app.textFields["connect.host"].exists)
        capture("usb-drawing-audio-muted", app: app)

        showDrawingControls(app, showing: app.buttons["display.settings"])
        app.buttons["display.settings"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).press(forDuration: 0.15)
        let unmuted = NSPredicate(format: "value == %@", "1")
        expectation(for: unmuted, evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        app.buttons["settings.done"].tap()
        assertTransport("USB", app: app)
        assertAudio("正在播放电脑声音", app: app)
        XCTAssertTrue(app.buttons["display.drawingControls"].exists)
        capture("usb-drawing-audio-unmuted", app: app)
    }

    func testUSBDrawingModeRespectsAudioOffAcrossCableReconnect() {
        let app = launchApp(drawingMode: true, audioEnabled: false)
        XCTAssertTrue(app.textFields["connect.host"].waitForExistence(timeout: 10))
        cable("START")
        assertTransport("USB", app: app)
        XCTAssertTrue(app.buttons["display.drawingControls"].exists)
        assertAudio("电脑声音已静音或不可用", app: app)
        showDrawingControls(app, showing: app.buttons["display.settings"])
        app.buttons["display.settings"].tap()
        let toggle = app.switches["settings.playPCaudio"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "Drawing must not force audio on")
        app.buttons["settings.done"].tap()
        cable("STOP")
        XCTAssertTrue(app.textFields["connect.host"].waitForExistence(timeout: 10))
        cable("START")
        assertTransport("USB", app: app)
        assertAudio("电脑声音已静音或不可用", app: app)
        XCTAssertTrue(app.buttons["display.drawingControls"].exists)
        capture("usb-drawing-audio-off-reconnected", app: app)
    }

    private func launchApp(autoconnect: String = "", drawingMode: Bool = false,
                           audioEnabled: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-didSeeOnboarding", "YES", "-allowUSB", "YES", "-autoReconnect", "YES",
                               "-lastHost", "",
                               "-drawingMode", drawingMode ? "YES" : "NO",
                               "-playPCaudio", audioEnabled ? "YES" : "NO"]
        app.launchEnvironment["EM_AUTOCONNECT"] = autoconnect
        app.launchEnvironment["EM_E2E_LOG"] = "1"
        app.launch()
        return app
    }

    private func assertTransport(_ name: String, app: XCUIApplication, timeout: TimeInterval = 10) {
        // A cable can arrive during the host's retry backoff. Wait for the
        // display before interacting; a premature gesture can hide its HUD.
        assertHUD(contains: name, app: app, timeout: timeout)
    }

    private func assertAudio(_ text: String, app: XCUIApplication) {
        assertHUD(contains: text, app: app, timeout: 10)
    }

    private func assertHUD(contains text: String, app: XCUIApplication, timeout: TimeInterval) {
        let hud = app.buttons["display.hud"]
        let matches = NSPredicate(format: "exists == true AND label CONTAINS %@", text)
        let deadline = Date().addingTimeInterval(timeout)
        // HUD controls fade after five seconds. A busy runner can spend the
        // remaining visible time checking USB before it checks mute status.
        // Reopen only a hidden HUD and require the same full status text;
        // waiting on a vanished element cannot prove or disprove audio state.
        while Date() < deadline {
            showDrawingControls(app, showing: hud)
            let check = XCTNSPredicateExpectation(predicate: matches, object: hud)
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            if XCTWaiter().wait(for: [check], timeout: min(2, remaining)) == .completed { return }
        }
        XCTFail("HUD never showed \"\(text)\"", file: #filePath, line: #line)
    }

    private func showDrawingControls(_ app: XCUIApplication, showing element: XCUIElement) {
        let drawingControls = app.buttons["display.drawingControls"]
        if !element.exists && drawingControls.exists { drawingControls.tap() }
    }

    private func cable(_ command: String) {
        let done = expectation(description: "USB fixture \(command)")
        let connection = NWConnection(host: "127.0.0.1", port: 19874, using: .tcp)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data("\(command)\n".utf8), completion: .contentProcessed { error in
                    XCTAssertNil(error)
                    connection.receive(minimumIncompleteLength: 3, maximumLength: 16) { data, _, _, error in
                        XCTAssertNil(error)
                        XCTAssertEqual(data, Data("OK\n".utf8))
                        done.fulfill()
                    }
                })
            }
        }
        connection.start(queue: DispatchQueue(label: "usb.ui.fixture"))
        wait(for: [done], timeout: 5)
        connection.cancel()
        connection.stateUpdateHandler = nil
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
