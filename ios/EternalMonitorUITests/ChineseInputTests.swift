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
        // stdout is deliberately a bounded lossy production log. Long-text
        // delivery is asserted against the host's explicit lossless recorder.
        logPath = try XCTUnwrap(ProcessInfo.processInfo.environment["EM_INPUT_RECORDER_FILE"])
        logOffset = (try? Data(contentsOf: URL(fileURLWithPath: logPath)).count) ?? 0
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        UIPasteboard.general.items = []
    }

    func testChineseAndEmojiDraftCanBeEditedBeforeSendingWithoutEnter() {
        let app = launchApp()
        let draft = openCleanKeyboard(app)
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
        let draft = openCleanKeyboard(app)
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

    func testLongChineseSubmissionStaysConnectedAndBackupRestoresOnlyWhenRequested() {
        let app = launchApp()
        let draft = openCleanKeyboard(app)
        let long = longDraft()
        let expected = draftCommands(long)
        paste(long, into: draft, app: app)
        XCTAssertTrue(injectionCommands().isEmpty, "A long draft remains local until explicitly submitted")

        app.buttons["keyboard.submit"].tap()
        waitForCommands(expected, timeout: 20)
        XCTAssertEqual(app.state, .runningForeground, "Sending a long draft must not crash the application")
        XCTAssertTrue(draft.exists, "Sending a long draft must not drop the streaming display")
        XCTAssertEqual(draft.value as? String, "")
        XCTAssertFalse(app.textFields["connect.host"].exists)
        XCTAssertEqual(injectionCommands(), expected,
                       "The host must receive every UTF-16 unit and newline exactly once, without an extra final Enter")
        capture("chinese-long-input-submitted", app: app)

        // Force termination, without dismissing the editor or disconnecting:
        // the submission backup must already be on disk before text is sent.
        app.terminate()
        let restarted = launchApp()
        let empty = openKeyboard(restarted)
        XCTAssertEqual(empty.value as? String, "", "A previous submission must not become an active draft on launch")
        assertCommandsRemain(expected, for: 1.5)
        let restore = restarted.buttons["keyboard.restore"]
        XCTAssertTrue(restore.exists)
        XCTAssertTrue(restore.isEnabled)
        restore.tap()
        XCTAssertTrue(appears(empty, where: "value == %@", long, within: 5))
        assertCommandsRemain(expected, for: 1.5)
        XCTAssertFalse(restore.isEnabled, "Recovery must not overwrite a nonempty draft")
        capture("chinese-long-input-backup-restored", app: restarted)

        restarted.buttons["keyboard.clear"].tap()
        restarted.buttons["keyboard.done"].tap()
        disconnect(restarted)
    }

    func testUnsubmittedLongDraftSurvivesForcedTerminationWithoutRemoteReplay() {
        let app = launchApp()
        let draft = openCleanKeyboard(app)
        let long = longDraft() + "这是尚未提交的本地草稿。"
        paste(long, into: draft, app: app)
        XCTAssertTrue(injectionCommands().isEmpty)
        // No Done/disconnect path is allowed to save on behalf of the editor:
        // this specifically exercises persistence while the editor is open.
        app.terminate()

        let restarted = launchApp()
        let restored = openKeyboard(restarted)
        XCTAssertEqual(restored.value as? String, long)
        assertCommandsRemain([], for: 1.5)
        XCTAssertFalse(restarted.buttons["keyboard.restore"].isEnabled,
                       "An earlier submission backup must not overwrite this recovered unsent draft")
        capture("chinese-long-draft-restarted", app: restarted)

        restarted.buttons["keyboard.clear"].tap()
        restarted.terminate()
        let cleared = launchApp()
        let empty = openKeyboard(cleared)
        XCTAssertEqual(empty.value as? String, "", "An explicit local clear must also survive application restart")
        assertCommandsRemain([], for: 1.5)
        cleared.buttons["keyboard.done"].tap()
        disconnect(cleared)
    }

    private func longDraft() -> String {
        (1...48).map { "第\($0)行：长文字请完整保存，表情😀与换行也要保留。\n" }.joined()
            + "最后一行：这是完整内容的结尾。"
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

    private func openCleanKeyboard(_ app: XCUIApplication) -> XCUIElement {
        let draft = openKeyboard(app)
        // Persistence intentionally survives launch. Each independent test
        // clears only its initial active draft through the same visible UI;
        // relaunch assertions call openKeyboard instead and never clear it.
        if let value = draft.value as? String, !value.isEmpty {
            app.buttons["keyboard.clear"].tap()
        }
        XCTAssertEqual(draft.value as? String, "")
        return draft
    }

    private func openKeyboard(_ app: XCUIApplication) -> XCUIElement {
        let toggle = app.buttons["display.keyboard"]
        let draft = app.textViews["keyboard.input"]
        let signal = app.descendants(matching: .any)["display.signal"].firstMatch
        for attempt in 1...3 {
            if draft.exists && app.keyboards.firstMatch.exists { return draft }
            // Finding controls during launch/dismissal may use almost all of
            // their five-second visible interval on a busy simulator. Wait
            // for that interval to finish, then reveal a fresh HUD instead
            // of tapping a button that is already about to disappear.
            if toggle.exists {
                _ = appears(toggle, where: "exists == false", within: 6)
            }
            if !toggle.exists { app.tap(withNumberOfTaps: 1, numberOfTouches: 3) }
            // A reconnecting display must recover before it can accept input.
            guard appears(signal, where: "exists == true AND label == %@", "正在传输", within: 3),
                  let frame = try? toggle.snapshot().frame, !frame.isEmpty else { continue }
            // snapshot() is throwable if the HUD faded during the lookup;
            // direct element.tap() fails the whole test in that same race.
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            if appears(draft, within: 3), appears(app.keyboards.firstMatch, within: 3) { return draft }
            recordDebug("chinese-input-open-attempt-\(attempt)", app: app)
        }
        recordDebug("chinese-input-open-failed", app: app)
        XCTFail("A connected display must open the native input draft")
        return draft
    }

    private func appears(_ element: XCUIElement, where format: String = "exists == true",
                         _ arguments: CVarArg..., within timeout: TimeInterval) -> Bool {
        let check = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: format, argumentArray: arguments), object: element)
        return XCTWaiter().wait(for: [check], timeout: timeout) == .completed
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

    private func draftCommands(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").utf16.flatMap { unit -> [String] in
            switch unit {
            case 10, 13:
                return ["KeyDown { scan: 28, extended: false }", "KeyUp { scan: 28, extended: false }"]
            case 9:
                return ["KeyDown { scan: 15, extended: false }", "KeyUp { scan: 15, extended: false }"]
            default:
                return ["Unicode(\(unit))"]
            }
        }
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

    private func waitForCommands(_ expected: [String], timeout: TimeInterval = 10) {
        expectation(for: NSPredicate { _, _ in self.injectionCommands() == expected }, evaluatedWith: nil)
        waitForExpectations(timeout: timeout)
    }

    private func assertCommandsRemain(_ expected: [String], for duration: TimeInterval) {
        XCTAssertEqual(injectionCommands(), expected)
        let unexpected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.injectionCommands() != expected
        }, object: nil)
        unexpected.isInverted = true
        XCTAssertEqual(XCTWaiter().wait(for: [unexpected], timeout: duration), .completed,
                       "Opening or restoring a draft must not transmit or replay any input")
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

    private func recordDebug(_ name: String, app: XCUIApplication) {
        capture(name, app: app)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)) {
            let log = XCTAttachment(string: String(decoding: data.suffix(16_384), as: UTF8.self))
            log.name = name + "-host-log-tail"
            log.lifetime = .keepAlways
            add(log)
        }
    }
}
