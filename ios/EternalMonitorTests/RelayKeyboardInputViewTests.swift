import UIKit
import XCTest
@testable import EternalMonitor

@MainActor
final class RelayKeyboardInputViewTests: XCTestCase {
    private func makeEditor() -> (RelayKeyboardInputView, RelayTouchUIView) {
        let relay = RelayTouchUIView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        relay.keyboardSupported = true
        let editor = RelayKeyboardInputView(frame: CGRect(x: 0, y: 0, width: 700, height: 106), textContainer: nil)
        editor.relay = relay
        editor.draftStore = KeyboardDraftStore(persistenceURL: nil)
        return (editor, relay)
    }

    func testSystemKeyboardIsNotRestrictedToASCII() {
        let (editor, _) = makeEditor()
        XCTAssertEqual(editor.keyboardType, .default)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.isSelectable)
        XCTAssertEqual(editor.accessibilityIdentifier, "keyboard.input")
    }

    func testLongDraftWaitsForEachAcceptedBatchAndKeepsRecoveryCopy() async {
        let (editor, relay) = makeEditor()
        let text = String(repeating: "中文😀\r\n", count: 150)
        editor.insertText(text)
        var events: [WireInputEvent] = []
        let finished = expectation(description: "Every bounded draft chunk was accepted")
        var expectedKeyboard = KeyboardRelayMachine()
        let expected = expectedKeyboard.text(text)
        relay.onDraftEvents = { batch, done in
            XCTAssertLessThanOrEqual(batch.count, 258)
            XCTAssertEqual(editor.draftStore?.lastSubmittedText, text,
                           "A recoverable copy must exist before the first write")
            events += batch
            DispatchQueue.main.async {
                done(true)
                if events.count == expected.count { finished.fulfill() }
            }
        }
        XCTAssertTrue(editor.submitDraft())
        XCTAssertTrue(editor.isSubmittingDraft)
        XCTAssertEqual(editor.text, text, "Do not erase a draft while only part of it has been accepted")
        XCTAssertFalse(editor.submitDraft(), "Repeated taps cannot start another transfer")
        editor.clearDraft()
        XCTAssertEqual(editor.text, text)
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(events, expected)
        XCTAssertEqual(editor.text, "")
        XCTAssertFalse(editor.isSubmittingDraft)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.restoreLastSubmission())
        XCTAssertEqual(editor.text, text)
        XCTAssertEqual(events, expected, "Restoring a backup must never send it")
        XCTAssertFalse(editor.restoreLastSubmission(), "Recovery cannot replace a nonempty draft")
    }

    func testFailedDraftTransportKeepsTextAndDoesNotRetryOrClear() {
        let (editor, relay) = makeEditor()
        let text = String(repeating: "保留草稿😀", count: 60)
        editor.insertText(text)
        var attempts = 0
        relay.onDraftEvents = { _, done in attempts += 1; done(false) }
        XCTAssertTrue(editor.submitDraft())
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(editor.text, text)
        XCTAssertEqual(editor.draftStore?.text, text)
        XCTAssertEqual(editor.draftStore?.lastSubmittedText, text)
        XCTAssertFalse(editor.isSubmittingDraft)
        XCTAssertTrue(editor.isEditable)
        editor.prepareForPresentation()
        XCTAssertEqual(attempts, 1, "Reopening after failure must not replay any text")
    }

    func testSubmissionDoesNotResumeAfterDisconnectEvenIfViewBecomesActiveAgain() async {
        let (editor, relay) = makeEditor()
        let text = String(repeating: "断线后不要接着输入", count: 80)
        editor.insertText(text)
        var callbacks: [(Bool) -> Void] = []
        relay.onDraftEvents = { _, done in callbacks.append(done) }
        var otherEvents: [WireInputEvent] = []
        relay.onEvents = { otherEvents += $0 }
        XCTAssertTrue(editor.submitDraft())
        XCTAssertEqual(callbacks.count, 1)
        relay.tapRemoteKey(0x28)
        relay.toggleRemoteModifier(0xe0)
        XCTAssertTrue(otherEvents.isEmpty, "Remote Enter and Ctrl cannot interrupt a text transfer")
        relay.active = false
        relay.active = true
        callbacks[0](true)
        await Task.yield()
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(editor.text, text)
        XCTAssertFalse(editor.isSubmittingDraft)
    }

    func testSuccessfulSubmissionClearsStoredDraftEvenWhenKeyboardWasDismissed() {
        let (editor, relay) = makeEditor()
        editor.insertText("收起也不能重新出现已发文字")
        var accepted: ((Bool) -> Void)?
        relay.onDraftEvents = { _, done in accepted = done }
        XCTAssertTrue(editor.submitDraft())
        // A real responder saves and freezes its local snapshot on dismissal.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(editor)
        window.makeKeyAndVisible()
        editor.becomeFirstResponder()
        editor.resignFirstResponder()
        accepted?(true)
        XCTAssertEqual(editor.draftStore?.text, "")
        XCTAssertEqual(editor.draftStore?.lastSubmittedText, "收起也不能重新出现已发文字")
        editor.prepareForPresentation()
        XCTAssertEqual(editor.text, "")
        window.isHidden = true
    }

    func testUnwritableBackupPreventsTransportAndRetainsDraft() throws {
        let (editor, relay) = makeEditor()
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        editor.draftStore = KeyboardDraftStore(persistenceURL: invalid.appendingPathComponent("draft.json"))
        editor.insertText("保存失败也要留下我")
        var events: [WireInputEvent] = []
        relay.onEvents = { events += $0 }
        XCTAssertFalse(editor.submitDraft())
        XCTAssertEqual(editor.text, "保存失败也要留下我")
        XCTAssertTrue(events.isEmpty)
    }

    func testMarkedPinyinNeverLeavesDraftAndCandidateCommitsOnlyOnce() {
        let (editor, relay) = makeEditor()
        var events: [WireInputEvent] = []
        relay.onEvents = { events += $0 }
        editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertNotNil(editor.markedTextRange)
        XCTAssertFalse(editor.submitDraft())
        XCTAssertTrue(events.isEmpty)
        // Candidate replacement is owned by UIKit, just like selecting 你好
        // from Pinyin's candidate row or accepting system handwriting.
        editor.setMarkedText("你好", selectedRange: NSRange(location: 2, length: 0))
        editor.unmarkText()
        XCTAssertNil(editor.markedTextRange)
        XCTAssertTrue(events.isEmpty, "Unmarking commits locally, never to the PC")
        XCTAssertTrue(editor.submitDraft())
        XCTAssertEqual(events.map(\.keycode), Array("你好".utf16))
        XCTAssertTrue(events.allSatisfy { $0.kind == 5 })
        XCTAssertEqual(editor.text, "")
        XCTAssertFalse(editor.submitDraft(), "An unchanged view cannot repeat a submission")
        XCTAssertEqual(events.count, 2)
    }

    func testDeletingCompositionAndClearingDraftAreEntirelyLocal() {
        let (editor, relay) = makeEditor()
        var events: [WireInputEvent] = []
        relay.onEvents = { events += $0 }
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        editor.deleteBackward()
        XCTAssertTrue(events.isEmpty)
        editor.clearDraft()
        XCTAssertNil(editor.markedTextRange)
        XCTAssertEqual(editor.text, "")
        XCTAssertTrue(events.isEmpty)
    }

    func testEmojiAndChineseDraftCanBeEditedBeforeTransmission() {
        let (editor, relay) = makeEditor()
        var events: [WireInputEvent] = []
        relay.onEvents = { events += $0 }
        editor.insertText("配方👨‍👩‍👧‍👦")
        editor.deleteBackward()
        XCTAssertEqual(editor.text, "配方", "Native deletion removes an extended grapheme, not one surrogate")
        editor.insertText("😀\n第二行")
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(editor.submitDraft(appendReturn: true))
        var expected = KeyboardRelayMachine()
        XCTAssertEqual(events, expected.text("配方😀\n第二行") + expected.tap(0x28))
    }

    func testPasteUsesNativeDocumentAndNeverInjectsBeforeSubmission() async throws {
        let (editor, relay) = makeEditor()
        var events: [WireInputEvent] = []
        relay.onEvents = { events += $0 }
        // UITextView's real paste pipeline needs an on-screen input document
        // and loads clipboard item providers asynchronously. An unattached
        // editor is not the same fixture as the visible keyboard panel.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        editor.frame = CGRect(x: 20, y: 80, width: min(700, window.bounds.width - 40), height: 106)
        controller.view.addSubview(editor)
        controller.view.layoutIfNeeded()
        let previous = UIPasteboard.general.items
        defer {
            editor.resignFirstResponder()
            editor.removeFromSuperview()
            window.isHidden = true
            previousWindow?.makeKey()
            UIPasteboard.general.items = previous
        }
        UIPasteboard.general.string = "中文，English 😀"
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !window.isHidden && window.isKeyWindow && editor.window === window
        }, object: nil)
        await fulfillment(of: [visible], timeout: 15)
        XCTAssertTrue(editor.becomeFirstResponder())
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            editor.isFirstResponder && editor.canPerformAction(
                #selector(UIResponderStandardEditActions.paste(_:)), withSender: nil)
        }, object: nil)
        await fulfillment(of: [ready], timeout: 15)
        // Item providers and the simulator's candidate service can complete
        // after unrelated text notifications. Wait for the real paste result,
        // rather than a fixed delay or the first notification from the editor.
        let pasted = expectation(forNotification: UITextView.textDidChangeNotification,
            object: editor) { notice in
                (notice.object as? UITextView)?.text == "中文，English 😀"
            }
        editor.paste(nil)
        await fulfillment(of: [pasted], timeout: 15)
        XCTAssertEqual(editor.text, "中文，English 😀")
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(editor.submitDraft())
        XCTAssertEqual(events.map(\.keycode), Array("中文，English 😀".utf16))
        XCTAssertTrue(events.allSatisfy { $0.kind == 5 })
    }

    func testUnavailableConnectionRetainsDraftAndDoesNotSend() {
        let (editor, relay) = makeEditor()
        var events: [WireInputEvent] = []
        relay.onEvents = { events += $0 }
        editor.insertText("保留草稿")
        relay.active = false
        XCTAssertFalse(editor.submitDraft(appendReturn: true))
        XCTAssertEqual(editor.text, "保留草稿")
        XCTAssertTrue(events.isEmpty)
        relay.active = true
        relay.keyboardSupported = false
        XCTAssertFalse(editor.submitDraft())
        XCTAssertEqual(editor.text, "保留草稿")
        XCTAssertTrue(events.isEmpty)
    }

    func testEmptyBackspaceAndExplicitNewlineStillWorkOnPC() {
        let (editor, relay) = makeEditor()
        var events: [WireInputEvent] = []
        relay.onEvents = { events += $0 }
        editor.deleteBackward()
        XCTAssertEqual(events.map(\.keycode), [0x2a, 0x2a])
        XCTAssertEqual(events.map(\.phase), [0, 2])
        events.removeAll()
        editor.insertText("一行\n")
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(editor.submitDraft())
        XCTAssertEqual(events.map(\.keycode), Array("一行".utf16) + [0x28, 0x28])
        XCTAssertEqual(events.suffix(2).map(\.phase), [0, 2])
    }

    func testSubmittingDraftReleasesRemoteModifierBeforeUnicode() {
        let (editor, relay) = makeEditor()
        var events: [WireInputEvent] = []
        relay.onEvents = { events += $0 }
        editor.insertText("中文")
        relay.toggleRemoteModifier(0xe0)
        events.removeAll()
        XCTAssertTrue(editor.submitDraft())
        XCTAssertEqual(events.first?.kind, 4)
        XCTAssertEqual(events.first?.keycode, 0xe0)
        XCTAssertEqual(events.first?.phase, 2)
        XCTAssertEqual(events.dropFirst().map(\.keycode), Array("中文".utf16))
        XCTAssertTrue(events.dropFirst().allSatisfy { $0.kind == 5 })
        XCTAssertFalse(relay.hasRemoteStickyModifiers)
    }

    func testDraftSurvivesViewRecreationWithoutCommittingMarkedPinyin() {
        let store = KeyboardDraftStore(persistenceURL: nil)
        let (first, firstRelay) = makeEditor()
        first.draftStore = store
        first.insertText("问题：")
        first.setMarkedText("weishenme", selectedRange: NSRange(location: 9, length: 0))
        XCTAssertNotNil(store.markedRange)
        let (restored, restoredRelay) = makeEditor()
        restored.draftStore = store
        XCTAssertEqual(restored.text, first.text)
        XCTAssertNotNil(restored.markedTextRange)
        var events: [WireInputEvent] = []
        firstRelay.onEvents = { events += $0 }
        restoredRelay.onEvents = { events += $0 }
        XCTAssertFalse(restored.submitDraft())
        XCTAssertTrue(events.isEmpty)
        restored.setMarkedText("为什么", selectedRange: NSRange(location: 3, length: 0))
        restored.unmarkText()
        XCTAssertTrue(restored.submitDraft())
        XCTAssertEqual(store.text, "")
        XCTAssertNil(store.markedRange)
        XCTAssertEqual(events.map(\.keycode), Array("问题：为什么".utf16))
    }

    func testExplicitRemoteStickyShortcutStillWorksWithoutDraft() {
        let (editor, relay) = makeEditor()
        var events: [WireInputEvent] = []
        relay.onEvents = { events += $0 }
        relay.toggleRemoteModifier(0xe0)
        events.removeAll()
        editor.insertText("c")
        XCTAssertEqual(editor.text, "")
        XCTAssertEqual(events.map(\.keycode), [0x06, 0x06, 0xe0])
        XCTAssertEqual(events.map(\.phase), [0, 2, 2])
        XCTAssertFalse(relay.hasRemoteStickyModifiers)
    }

    func testDraftLayoutAvoidsDockedAndFloatingKeyboardsInBothOrientations() {
        for size in [CGSize(width: 1024, height: 768), CGSize(width: 768, height: 1024)] {
            let bounds = CGRect(origin: .zero, size: size)
            let docked = CGRect(x: 0, y: size.height - 360, width: size.width, height: 360)
            let dockedDraft = KeyboardDraftLayout.frame(in: bounds, safeArea: .zero, keyboard: docked)
            XCTAssertFalse(dockedDraft.intersects(docked))
            XCTAssertEqual(dockedDraft.height, 106)
            let floatingTop = CGRect(x: 100, y: 18, width: 320, height: 300)
            let below = KeyboardDraftLayout.frame(in: bounds, safeArea: .zero, keyboard: floatingTop)
            XCTAssertFalse(below.intersects(floatingTop))
            XCTAssertEqual(below.height, 106)
            let floatingBottom = CGRect(x: 100, y: size.height - 200, width: 320, height: 300)
            let above = KeyboardDraftLayout.frame(in: bounds, safeArea: .zero, keyboard: floatingBottom)
            XCTAssertFalse(above.intersects(floatingBottom))
            XCTAssertEqual(above.height, 106)
            XCTAssertTrue(bounds.contains(above))
        }
        let narrow = KeyboardDraftLayout.frame(in: CGRect(x: 0, y: 0, width: 320, height: 600),
            safeArea: .zero, keyboard: nil)
        XCTAssertEqual(narrow.width, 304)
        XCTAssertEqual(narrow.height, 106)
    }
}
