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
        return (editor, relay)
    }

    func testSystemKeyboardIsNotRestrictedToASCII() {
        let (editor, _) = makeEditor()
        XCTAssertEqual(editor.keyboardType, .default)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.isSelectable)
        XCTAssertEqual(editor.accessibilityIdentifier, "keyboard.input")
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

    func testPasteUsesNativeDocumentAndNeverInjectsBeforeSubmission() {
        let (editor, relay) = makeEditor()
        var events: [WireInputEvent] = []
        relay.onEvents = { events += $0 }
        let previous = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previous }
        UIPasteboard.general.string = "中文，English 😀"
        editor.paste(nil)
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
        let store = KeyboardDraftStore()
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
