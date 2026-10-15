import UIKit
import XCTest

/// Use UIKit's actual text editor and edit menu. The fixture clipboard avoids
/// depending on which Chinese keyboards happen to be installed on the runner;
/// marked-text composition itself is covered by the input-view unit tests.
final class ChineseInputTests: XCTestCase {
    private var logPath: String!
    private var logOffset = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        logPath = try XCTUnwrap(ProcessInfo.processInfo.environment["EM_INPUT_HOST_LOG"])
        logOffset = (try? Data(contentsOf: URL(fileURLWithPath: logPath)).count) ?? 0
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        UIPasteboard.general.items = []
    }

    func testChineseAndEmojiDraftCanBeEditedBeforeSendingWithoutEnter() {
        let app = launchApp()
        let draft = openKeyboard(app)
        paste("配方😀错误", into: draft, app: app)
        draft.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
        XCTAssertEqual(draft.value as? String, "配方😀")
        XCTAssertTrue(injectionCommands().isEmpty,
                      "Pasting, choosing text and deleting locally must not type into the PC")
        capture("chinese-input-draft", app: app)

        app.buttons["keyboard.submit"].tap()
        waitForCommands(unicodeCommands("配方😀"))
        XCTAssertEqual(draft.value as? String, "")
        XCTAssertEqual(injectionCommands(), unicodeCommands("配方😀"),
                       "Input to PC must preserve both emoji UTF-16 units and must not append Enter")
        capture("chinese-input-submitted", app: app)

        // Clearing another draft is local editing, not a remote Delete key.
        draft.typeText("discard")
        app.buttons["keyboard.clear"].tap()
        XCTAssertEqual(draft.value as? String, "")
        XCTAssertEqual(injectionCommands(), unicodeCommands("配方😀"))
        app.buttons["keyboard.done"].tap()
        disconnect(app)
    }

    func testClosingKeepsDraftAndReturnIsSentOnlyWhenRequested() {
        let app = launchApp()
        let draft = openKeyboard(app)
        draft.typeText("keep")
        app.buttons["keyboard.done"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(injectionCommands().isEmpty)

        let restored = openKeyboard(app)
        XCTAssertEqual(restored.value as? String, "keep")
        app.buttons["keyboard.submitReturn"].tap()
        let expected = unicodeCommands("keep") + [
            "KeyDown { scan: 28, extended: false }",
            "KeyUp { scan: 28, extended: false }"
        ]
        waitForCommands(expected)
        XCTAssertEqual(restored.value as? String, "")
        app.buttons["keyboard.done"].tap()

        let reopened = openKeyboard(app)
        XCTAssertEqual(reopened.value as? String, "")
        XCTAssertEqual(injectionCommands(), expected,
                       "Reopening the input panel must not replay a submitted draft")
        capture("chinese-input-explicit-return", app: app)
        app.buttons["keyboard.done"].tap()
        disconnect(app)
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-didSeeOnboarding", "YES", "-allowUSB", "NO", "-controlPC", "YES",
                               "-drawingMode", "NO", "-playPCaudio", "NO"]
        app.launchEnvironment["EM_AUTOCONNECT"] = ProcessInfo.processInfo.environment["EM_INPUT_HOST"] ?? "127.0.0.1:19875"
        app.launchEnvironment["EM_E2E_LOG"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["display.keyboard"].waitForExistence(timeout: 15))
        return app
    }

    private func openKeyboard(_ app: XCUIApplication) -> XCUIElement {
        let toggle = app.buttons["display.keyboard"]
        if !toggle.exists { app.tap(withNumberOfTaps: 1, numberOfTouches: 3) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        let draft = app.textViews["keyboard.input"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        return draft
    }

    private func paste(_ text: String, into draft: XCUIElement, app: XCUIApplication) {
        UIPasteboard.general.string = text
        draft.press(forDuration: 1.1)
        let paste = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["Paste", "粘贴", "貼上"])).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "Native text editor must expose Paste")
        paste.tap()
        let allow = app.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Allow Paste", "允许粘贴", "允許貼上"])).firstMatch
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        expectation(for: NSPredicate(format: "value == %@", text), evaluatedWith: draft)
        waitForExpectations(timeout: 5)
    }

    private func unicodeCommands(_ text: String) -> [String] {
        text.utf16.map { "Unicode(\($0))" }
    }

    private func injectionCommands() -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)), data.count >= logOffset else { return [] }
        let log = String(decoding: data.dropFirst(logOffset), as: UTF8.self)
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        return log
            .components(separatedBy: .newlines).compactMap { line in
                guard let range = line.range(of: "Input injection command=") else { return nil }
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    private func waitForCommands(_ expected: [String]) {
        expectation(for: NSPredicate { _, _ in self.injectionCommands() == expected }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
    }

    private func disconnect(_ app: XCUIApplication) {
        if !app.buttons["display.disconnect"].exists { app.tap(withNumberOfTaps: 1, numberOfTouches: 3) }
        app.buttons["display.disconnect"].tap()
        XCTAssertTrue(app.textFields["connect.host"].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
