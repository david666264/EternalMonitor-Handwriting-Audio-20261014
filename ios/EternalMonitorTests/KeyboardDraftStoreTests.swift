import Foundation
import XCTest
@testable import EternalMonitor

@MainActor
final class KeyboardDraftStoreTests: XCTestCase {
    private func withDraftFile(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder.appendingPathComponent("draft.json"))
    }

    func testFreshStoreRestoresTextSelectionAndUncommittedPinyin() throws {
        try withDraftFile { url in
            let first = KeyboardDraftStore(persistenceURL: url)
            first.update(text: "问题😀：weishenme", selection: NSRange(location: 14, length: 0),
                markedRange: NSRange(location: 5, length: 9))
            XCTAssertTrue(first.flush())
            let restored = KeyboardDraftStore(persistenceURL: url)
            XCTAssertEqual(restored.text, "问题😀：weishenme")
            XCTAssertEqual(restored.selection, NSRange(location: 14, length: 0))
            XCTAssertEqual(restored.markedRange, NSRange(location: 5, length: 9))
        }
    }

    func testNewStoreWaitsForQueuedAtomicSaveWithoutExplicitFlush() throws {
        try withDraftFile { url in
            let first = KeyboardDraftStore(persistenceURL: url)
            first.update(text: "刚打好的草稿", selection: NSRange(location: 7, length: 0), markedRange: nil)
            let restored = KeyboardDraftStore(persistenceURL: url)
            XCTAssertEqual(restored.text, "刚打好的草稿")
        }
    }

    func testExplicitClearSurvivesRestartAndDoesNotRestorePreviousText() throws {
        try withDraftFile { url in
            let store = KeyboardDraftStore(persistenceURL: url)
            store.update(text: "稍后清空", selection: NSRange(location: 4, length: 0), markedRange: nil)
            XCTAssertTrue(store.flush())
            store.update(text: "", selection: NSRange(location: 0, length: 0), markedRange: nil)
            XCTAssertTrue(store.flush())
            let restored = KeyboardDraftStore(persistenceURL: url)
            XCTAssertEqual(restored.text, "")
            XCTAssertEqual(restored.selection, NSRange(location: 0, length: 0))
            XCTAssertNil(restored.markedRange)
        }
    }

    func testLongRapidUpdatesSaveLatestGenerationWithUnicodeIntact() throws {
        try withDraftFile { url in
            let store = KeyboardDraftStore(persistenceURL: url)
            let long = String(repeating: "中文😀一行。\n", count: 15_000)
            for index in 0..<25 {
                let value = long + "末尾\(index)"
                store.update(text: value, selection: NSRange(location: value.utf16.count, length: 0), markedRange: nil)
            }
            XCTAssertTrue(store.flush())
            let restored = KeyboardDraftStore(persistenceURL: url)
            XCTAssertEqual(restored.text, long + "末尾24")
            XCTAssertEqual(restored.selection.location, restored.text.utf16.count)
        }
    }

    func testLengthLimitRejectsOversizedTextWithoutTruncationOrReplacingPreviousDraft() {
        let store = KeyboardDraftStore(persistenceURL: nil)
        XCTAssertTrue(store.update(text: "保留原文😀", selection: NSRange(location: 6, length: 0), markedRange: nil))
        let prefix = String(repeating: "a", count: KeyboardDraftStore.maximumUTF16Length - 1)
        XCTAssertFalse(store.update(text: prefix + "😀结尾", selection: NSRange(location: NSNotFound, length: NSNotFound), markedRange: nil))
        XCTAssertEqual(store.text, "保留原文😀")
        XCTAssertEqual(store.selection, NSRange(location: 6, length: 0))
        XCTAssertTrue(store.flush())
    }

    func testInvalidRangesAreClampedWithoutOverflowOrHalfSurrogates() {
        let value = "中😀文"
        XCTAssertEqual(KeyboardDraftStore.sanitizedRange(NSRange(location: NSNotFound, length: NSNotFound), in: value),
            NSRange(location: 4, length: 0))
        XCTAssertEqual(KeyboardDraftStore.sanitizedRange(NSRange(location: 2, length: 0), in: value),
            NSRange(location: 1, length: 0))
        XCTAssertEqual(KeyboardDraftStore.sanitizedRange(NSRange(location: 2, length: 1), in: value),
            NSRange(location: 1, length: 2))
        XCTAssertEqual(KeyboardDraftStore.sanitizedRange(NSRange(location: -10, length: Int.max), in: value),
            NSRange(location: 0, length: 4))
        let store = KeyboardDraftStore(persistenceURL: nil)
        store.update(text: value, selection: NSRange(location: 0, length: Int.max),
            markedRange: NSRange(location: NSNotFound, length: Int.max))
        XCTAssertEqual(store.selection, NSRange(location: 0, length: 4))
        XCTAssertNil(store.markedRange)
    }

    func testMalformedOrFutureSnapshotStartsEmptyAndCanBeReplaced() throws {
        try withDraftFile { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            for data in [Data("not JSON".utf8), Data("{\"schemaVersion\":999,\"text\":\"旧草稿\",\"selection\":{\"location\":0,\"length\":0}}".utf8)] {
                try data.write(to: url, options: .atomic)
                let store = KeyboardDraftStore(persistenceURL: url)
                XCTAssertEqual(store.text, "")
                XCTAssertTrue(store.restorationFailed)
                store.update(text: "新草稿", selection: NSRange(location: 3, length: 0), markedRange: nil)
                XCTAssertTrue(store.flush())
                XCTAssertEqual(KeyboardDraftStore(persistenceURL: url).text, "新草稿")
                let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                XCTAssertTrue(files.contains { $0.lastPathComponent.hasPrefix("draft-unreadable-") && (try? Data(contentsOf: $0)) == data })
            }
        }
    }

    func testSubmissionBackupSurvivesClearAndRestartAndCanBeRestored() throws {
        try withDraftFile { url in
            let store = KeyboardDraftStore(persistenceURL: url)
            let submitted = String(repeating: "需要保留的提交😀\n", count: 8_000)
            store.update(text: submitted, selection: NSRange(location: submitted.utf16.count, length: 0), markedRange: nil)
            XCTAssertTrue(store.rememberSubmission(submitted))
            store.update(text: "", selection: NSRange(location: 0, length: 0), markedRange: nil)
            XCTAssertTrue(store.flush())
            let restored = KeyboardDraftStore(persistenceURL: url)
            XCTAssertEqual(restored.text, "")
            XCTAssertEqual(restored.lastSubmittedText, submitted)
            XCTAssertTrue(restored.restoreLastSubmission())
            XCTAssertEqual(restored.text, submitted)
            XCTAssertEqual(restored.selection.location, submitted.utf16.count)
            XCTAssertNil(restored.markedRange)
            XCTAssertEqual(KeyboardDraftStore(persistenceURL: url).text, submitted)
        }
    }

    func testOversizedSubmissionDoesNotReplaceExistingRecoveryCopy() {
        let store = KeyboardDraftStore(persistenceURL: nil)
        XCTAssertFalse(store.restoreLastSubmission())
        XCTAssertTrue(store.rememberSubmission("上一份😀"))
        XCTAssertFalse(store.rememberSubmission(String(repeating: "x", count: KeyboardDraftStore.maximumUTF16Length + 1)))
        XCTAssertEqual(store.lastSubmittedText, "上一份😀")
        XCTAssertTrue(store.restoreLastSubmission())
        XCTAssertEqual(store.text, "上一份😀")
    }

    func testStoredRangesAreSanitizedOnDiskRestore() throws {
        try withDraftFile { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data("{\"schemaVersion\":1,\"text\":\"中😀文\",\"selection\":{\"location\":2,\"length\":9223372036854775807},\"markedRange\":{\"location\":-1,\"length\":99}}".utf8)
            try data.write(to: url)
            let store = KeyboardDraftStore(persistenceURL: url)
            XCTAssertEqual(store.text, "中😀文")
            XCTAssertEqual(store.selection, NSRange(location: 1, length: 3))
            XCTAssertNil(store.markedRange)
        }
    }

    func testPersistenceFailureIsReportedAndMemoryDraftRemainsAvailable() throws {
        try withDraftFile { url in
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            // A regular file where a directory is required gives a stable IO
            // failure without changing sandbox permissions or device storage.
            let blockingFile = parent.appendingPathComponent("not-a-directory")
            try Data().write(to: blockingFile)
            let store = KeyboardDraftStore(persistenceURL: blockingFile.appendingPathComponent("draft.json"))
            store.update(text: "仍在内存里", selection: NSRange(location: 5, length: 0), markedRange: nil)
            XCTAssertFalse(store.flush())
            XCTAssertEqual(store.text, "仍在内存里")
        }
    }
}
