import XCTest

final class KeyboardRelayTests: XCTestCase {
    func testKeyboardRelay() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(environment["EM_INPUT_HOST_LOG"])
        let before = (try? Data(contentsOf: URL(fileURLWithPath: path)).count) ?? 0
        let app = XCUIApplication()
        app.launchArguments = ["-didSeeOnboarding", "YES", "-allowUSB", "NO", "-controlPC", "YES", "-playPCaudio", "NO"]
        app.launchEnvironment["EM_AUTOCONNECT"] = environment["EM_INPUT_HOST"] ?? "127.0.0.1:19875"
        app.launchEnvironment["EM_E2E_LOG"] = "1"
        app.launch()
        let keyboard = app.buttons["display.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 15))
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let draft = app.textViews["keyboard.input"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.typeText("Hi!")
        XCTAssertTrue(injections(path: path, after: before).isEmpty,
                      "Draft editing must not type into the PC before confirmation")
        app.buttons["keyboard.submitReturn"].tap()
        let commands = ["Unicode(72)", "Unicode(105)", "Unicode(33)", "KeyDown { scan: 28, extended: false }", "KeyUp { scan: 28, extended: false }"]
        let relayed = NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count >= before else { return false }
            let log = String(decoding: data.dropFirst(before), as: UTF8.self)
            return commands.allSatisfy { log.contains($0) }
        }
        expectation(for: relayed, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        capture("keyboard-relay", app: app)
        let control = app.buttons["keyboard.key.224"]
        control.tap()
        XCTAssertEqual(control.value as? String, "已按下")
        app.buttons["keyboard.key.80"].tap()
        XCTAssertEqual(control.value as? String, "未按下")
        // The app's stable close control works regardless of the simulator's
        // system-keyboard language or floating/docked layout.
        app.buttons["keyboard.done"].tap()
        verifyDismissalAndRestoreHUD(app: app, keyboard: keyboard)
        capture("keyboard-dismissed", app: app)
        keyboard.tap()
        XCTAssertTrue(app.buttons["keyboard.done"].waitForExistence(timeout: 5))
        app.buttons["keyboard.done"].tap()
        verifyDismissalAndRestoreHUD(app: app, keyboard: keyboard)
        app.buttons["display.disconnect"].tap()
        XCTAssertTrue(app.textFields["connect.host"].waitForExistence(timeout: 5))
        app.terminate()
    }

    private func verifyDismissalAndRestoreHUD(app: XCUIApplication, keyboard: XCUIElement) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        // Accessibility queries may outlast the normal HUD timer. Prove the
        // timeout first, then bring the controls back before checking state.
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: keyboard)
        waitForExpectations(timeout: 6)
        app.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertEqual(keyboard.label, "键盘")
        XCTAssertTrue(app.buttons["display.disconnect"].exists)
    }

    private func injections(path: String, after offset: Int) -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count >= offset else { return [] }
        return String(decoding: data.dropFirst(offset), as: UTF8.self)
            .components(separatedBy: .newlines).filter { $0.contains("Input injection command=") }
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
