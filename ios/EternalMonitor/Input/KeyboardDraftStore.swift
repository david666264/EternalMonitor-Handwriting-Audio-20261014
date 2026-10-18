import Foundation

/// One app-wide local document. Rebuilding the keyboard or reconnecting must
/// not discard text, and restarting the app restores the latest saved draft.
/// Each change queues an atomic write immediately (there is no debounce).
/// Only the latest pending snapshot is retained while a write is in progress.
/// Call `flush()` when hiding the editor or entering the background to wait for
/// pending writes. No draft contents are logged or sent over the connection.
@MainActor
final class KeyboardDraftStore {
    nonisolated static let maximumUTF16Length = 1_000_000

    private(set) var text = ""
    private(set) var selection = NSRange(location: 0, length: 0)
    private(set) var markedRange: NSRange?
    private(set) var lastSubmittedText = ""
    private(set) var restorationFailed = false
    private let writer: KeyboardDraftPersistenceWriter?

    /// Passing nil makes a fully in-memory document, including in unit tests.
    init(persistenceURL: URL? = KeyboardDraftStore.defaultPersistenceURL) {
        guard let persistenceURL else {
            writer = nil
            return
        }
        // Loading shares the writer queue, so a newly created store cannot
        // race the previous store's already queued save to this same file.
        let result = KeyboardDraftPersistenceWriter.load(from: persistenceURL)
        restorationFailed = result.requiresBackup
        writer = KeyboardDraftPersistenceWriter(url: persistenceURL, requiresBackup: result.requiresBackup)
        guard let saved = result.snapshot else { return }
        text = saved.text
        selection = Self.sanitizedRange(saved.selection.nsRange, in: text)
        markedRange = Self.sanitizedMarkedRange(saved.markedRange?.nsRange, in: text)
        lastSubmittedText = saved.lastSubmittedText
    }

    /// Text and both UIKit ranges move together; three independent assignments
    /// could otherwise save a new string with an old, invalid selection.
    @discardableResult
    func update(text: String, selection: NSRange, markedRange: NSRange?) -> Bool {
        // The editor gates this limit before accepting input. As a second
        // boundary, never silently save a truncated version of a user's text.
        guard (text as NSString).length <= Self.maximumUTF16Length else { return false }
        let selected = Self.sanitizedRange(selection, in: text)
        let marked = Self.sanitizedMarkedRange(markedRange, in: text)
        guard self.text != text || self.selection != selected || self.markedRange != marked else { return true }
        self.text = text
        self.selection = selected
        self.markedRange = marked
        enqueueSnapshot()
        return true
    }

    /// Save a recovery copy *before* starting transport. Sending/clearing a
    /// draft never erases this last submission, including after a crash.
    @discardableResult
    func rememberSubmission(_ text: String) -> Bool {
        guard !text.isEmpty, (text as NSString).length <= Self.maximumUTF16Length else { return false }
        lastSubmittedText = text
        enqueueSnapshot()
        return flush()
    }

    /// The caller owns confirmation when this would replace another draft.
    @discardableResult
    func restoreLastSubmission() -> Bool {
        guard !lastSubmittedText.isEmpty else { return false }
        let recovered = lastSubmittedText
        guard update(text: recovered, selection: NSRange(location: (recovered as NSString).length, length: 0),
            markedRange: nil) else { return false }
        return flush()
    }

    private func enqueueSnapshot() {
        writer?.enqueue(KeyboardDraftSnapshot(text: text, selection: selection, markedRange: markedRange,
            lastSubmittedText: lastSubmittedText))
    }

    /// A true result means every update preceding this call has reached an
    /// atomic file write, or persistence was explicitly disabled with nil.
    /// Failure is inspectable by the UI without printing private draft text.
    @discardableResult
    func flush() -> Bool { writer?.flush() ?? true }

    nonisolated static var defaultPersistenceURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EternalMonitor", isDirectory: true)
            .appendingPathComponent("Keyboard", isDirectory: true)
            .appendingPathComponent("draft-v1.json", isDirectory: false)
    }

    /// NSRange arithmetic is performed only after clamping: NSNotFound and a
    /// malicious/obsolete range must not overflow `location + length`. UIKit
    /// offsets are UTF-16, so endpoints also must not bisect an emoji surrogate.
    nonisolated static func sanitizedRange(_ range: NSRange, in text: String) -> NSRange {
        let string = text as NSString
        let count = string.length
        let rawStart = range.location == NSNotFound ? count : min(count, max(0, range.location))
        let rawLength = min(count - rawStart, max(0, range.length))
        let rawEnd = rawStart + rawLength
        let start = boundaryBeforeOrAt(rawStart, in: string)
        // An invalid caret collapses before the scalar. A selected scalar is
        // expanded as a whole rather than leaving half of its surrogate pair.
        let end = rawLength == 0 ? start : boundaryAfterOrAt(rawEnd, in: string)
        return NSRange(location: start, length: end - start)
    }

    nonisolated static func sanitizedMarkedRange(_ range: NSRange?, in text: String) -> NSRange? {
        guard let range, range.location != NSNotFound, range.location >= 0,
              range.length > 0, range.location < (text as NSString).length else { return nil }
        let result = sanitizedRange(range, in: text)
        return result.length > 0 ? result : nil
    }

    private nonisolated static func boundaryBeforeOrAt(_ offset: Int, in string: NSString) -> Int {
        guard offset > 0, offset < string.length,
              isHighSurrogate(string.character(at: offset - 1)),
              isLowSurrogate(string.character(at: offset)) else { return offset }
        return offset - 1
    }

    private nonisolated static func boundaryAfterOrAt(_ offset: Int, in string: NSString) -> Int {
        guard offset > 0, offset < string.length,
              isHighSurrogate(string.character(at: offset - 1)),
              isLowSurrogate(string.character(at: offset)) else { return offset }
        return offset + 1
    }

    private nonisolated static func isHighSurrogate(_ unit: unichar) -> Bool { (0xd800...0xdbff).contains(unit) }
    private nonisolated static func isLowSurrogate(_ unit: unichar) -> Bool { (0xdc00...0xdfff).contains(unit) }
}

private struct KeyboardDraftRange: Codable {
    let location: Int
    let length: Int
    init(_ range: NSRange) { location = range.location; length = range.length }
    var nsRange: NSRange { NSRange(location: location, length: length) }
}

private struct KeyboardDraftSnapshot: Codable {
    let schemaVersion: Int
    let text: String
    let selection: KeyboardDraftRange
    let markedRange: KeyboardDraftRange?
    let lastSubmittedText: String

    init(text: String, selection: NSRange, markedRange: NSRange?, lastSubmittedText: String) {
        schemaVersion = 1
        self.text = text
        self.selection = KeyboardDraftRange(selection)
        self.markedRange = markedRange.map(KeyboardDraftRange.init)
        self.lastSubmittedText = lastSubmittedText
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, text, selection, markedRange, lastSubmittedText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        text = try container.decode(String.self, forKey: .text)
        selection = try container.decode(KeyboardDraftRange.self, forKey: .selection)
        markedRange = try container.decodeIfPresent(KeyboardDraftRange.self, forKey: .markedRange)
        lastSubmittedText = try container.decodeIfPresent(String.self, forKey: .lastSubmittedText) ?? ""
    }
}

private struct KeyboardDraftLoadResult {
    let snapshot: KeyboardDraftSnapshot?
    let requiresBackup: Bool
}

/// File IO stays off the main thread. The bounded single pending slot avoids
/// retaining one full long-document copy per keystroke when storage is busy.
private final class KeyboardDraftPersistenceWriter: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "EternalMonitor.keyboard-draft", qos: .userInitiated)
    private let url: URL
    private let lock = NSLock()
    private var pending: (generation: UInt64, snapshot: KeyboardDraftSnapshot)?
    private var scheduled = false
    private var generation: UInt64 = 0
    private var completedGeneration: UInt64 = 0
    private var lastWriteSucceeded = true
    private var directoryPrepared = false
    private var requiresBackup: Bool

    init(url: URL, requiresBackup: Bool) { self.url = url; self.requiresBackup = requiresBackup }

    static func load(from url: URL) -> KeyboardDraftLoadResult {
        queue.sync {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return KeyboardDraftLoadResult(snapshot: nil, requiresBackup: false)
            }
            // Both capped strings fit below 16 MiB even when each UTF-16
            // unit requires JSON escaping. Never truncate an oversized draft.
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, size <= 16 * 1_024 * 1_024,
                  let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(KeyboardDraftSnapshot.self, from: data),
                  snapshot.schemaVersion == 1,
                  (snapshot.text as NSString).length <= KeyboardDraftStore.maximumUTF16Length,
                  (snapshot.lastSubmittedText as NSString).length <= KeyboardDraftStore.maximumUTF16Length else {
                return KeyboardDraftLoadResult(snapshot: nil, requiresBackup: true)
            }
            return KeyboardDraftLoadResult(snapshot: snapshot, requiresBackup: false)
        }
    }

    func enqueue(_ snapshot: KeyboardDraftSnapshot) {
        lock.lock()
        generation &+= 1
        pending = (generation, snapshot)
        let needsScheduling = !scheduled
        scheduled = true
        lock.unlock()
        if needsScheduling { Self.queue.async { self.drain() } }
    }

    func flush() -> Bool {
        Self.queue.sync {}
        lock.lock()
        defer { lock.unlock() }
        return completedGeneration == generation && lastWriteSucceeded
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = pending else {
                scheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            let success: Bool
            do {
                if !directoryPrepared {
                    var directory = url.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try directory.setResourceValues(values)
                    directoryPrepared = true
                }
                if requiresBackup {
                    // Preserve the unreadable source before ever replacing
                    // it. A failed copy fails the save and leaves it intact.
                    let backup = url.deletingLastPathComponent()
                        .appendingPathComponent("draft-unreadable-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: url, to: backup)
                    try FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: backup.path)
                    requiresBackup = false
                }
                let data = try JSONEncoder().encode(next.snapshot)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                success = true
            } catch {
                // The caller can surface a failed flush; draft contents and
                // private filesystem locations never enter the log.
                success = false
            }
            lock.lock()
            completedGeneration = next.generation
            lastWriteSucceeded = success
            lock.unlock()
        }
    }
}
