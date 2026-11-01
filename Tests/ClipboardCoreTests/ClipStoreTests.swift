import Foundation
import Testing

@testable import ClipboardCore

final class TemporaryStore {
    let directory: URL
    let store: ClipStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("paste-tests-\(UUID().uuidString)")
        store = try ClipStore(directory: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    func add(
        _ text: String, app: String? = "com.example.app", name: String = "Example", at date: Date = Date(),
        secrets: SecretHandling = .skip
    ) throws -> Clip {
        let draft = try #require(draft(from: [[utf8Rep(text)]], secrets: secrets, app: app).map { $0 })
        let renamed = ClipDraft(
            kind: draft.kind, text: draft.text, items: draft.items, hash: draft.hash,
            source: ClipSource(bundleID: app, name: name), byteSize: draft.byteSize, pixelWidth: nil, pixelHeight: nil,
            thumbnail: nil, isSecret: draft.isSecret)
        return try store.capture(renamed, at: date).clip
    }
}

@Suite struct SecretClipTests {
    private let secret = "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"

    @Test func hiddenClipsShowDotsButKeepTheirContent() throws {
        let temp = try TemporaryStore()
        let clip = try temp.add(secret, secrets: .hide)
        #expect(clip.isHidden)
        #expect(clip.preview == Clip.hiddenPreview)
        #expect(try temp.store.fullText(clipID: clip.id) == secret)
        let payload = try temp.store.payload(for: clip)
        #expect(String(decoding: payload[0][0].data, as: UTF8.self) == secret)
    }

    @Test func ordinaryClipsAreNeverHidden() throws {
        let temp = try TemporaryStore()
        let clip = try temp.add("Just a note", secrets: .hide)
        #expect(!clip.isHidden)
        #expect(clip.preview == "Just a note")
    }

    @Test func changingTheSettingAppliesToSavedClips() throws {
        let temp = try TemporaryStore()
        let saved = try temp.add(secret, secrets: .hide)

        temp.store.hidesSecrets = false
        let shown = try #require(try temp.store.clip(id: saved.id))
        #expect(shown.isSecret)
        #expect(!shown.isHidden)
        #expect(shown.preview == secret)

        temp.store.hidesSecrets = true
        let hidden = try #require(try temp.store.clip(id: saved.id))
        #expect(hidden.isHidden)
        #expect(hidden.preview == Clip.hiddenPreview)
    }

    @Test func aHiddenLinkDoesNotShowItsFetchedTitle() throws {
        let temp = try TemporaryStore()
        let url = "https://example.com/?key=ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let saved = try temp.add(url, secrets: .show)
        try temp.store.setLinkMetadata(title: "Account page", thumbnail: nil, clipID: saved.id)
        #expect(try temp.store.clip(id: saved.id)?.linkTitle == nil)
        temp.store.hidesSecrets = false
        #expect(try temp.store.clip(id: saved.id)?.linkTitle == "Account page")
    }

    @Test func hiddenClipsCanBeFoundByTheirRealText() throws {
        let temp = try TemporaryStore()
        let saved = try temp.add(secret, secrets: .hide)
        try temp.add("Just a note")
        let found = try temp.store.clips(ClipQuery(text: "ghp_abc"))
        #expect(found.map(\.id) == [saved.id])
        #expect(found.first?.preview == Clip.hiddenPreview)
    }

    @Test func renamingKeepsAClipHidden() throws {
        let temp = try TemporaryStore()
        let saved = try temp.add(secret, secrets: .hide)
        try temp.store.rename(clipID: saved.id, title: "Deploy key")
        let renamed = try #require(try temp.store.clip(id: saved.id))
        #expect(renamed.title == "Deploy key")
        #expect(renamed.isHidden)
    }

    @Test func queriesCanLeaveSecretsOut() throws {
        let temp = try TemporaryStore()
        try temp.add(secret, secrets: .hide)
        let note = try temp.add("Just a note")
        #expect(try temp.store.clips(ClipQuery(excludesSecrets: true)).map(\.id) == [note.id])
        #expect(try temp.store.clips(ClipQuery(text: "ghp_abc", excludesSecrets: true)).isEmpty)
    }

    @Test func upgradingFlagsSecretsAlreadyInHistory() throws {
        let temp = try TemporaryStore()
        let saved = try temp.add(secret, secrets: .show)
        let note = try temp.add("Just a note")
        let database = try Database(path: temp.directory.appendingPathComponent("history.sqlite").path, readOnly: false)
        try database.script(
            "ALTER TABLE clips DROP COLUMN is_secret; ALTER TABLE clips DROP COLUMN has_icon; ALTER TABLE clips DROP COLUMN link_checked; PRAGMA user_version = 1")

        let upgraded = try ClipStore(directory: temp.directory)
        #expect(try upgraded.clip(id: saved.id)?.isHidden == true)
        #expect(try upgraded.clip(id: note.id)?.isSecret == false)
    }
}

@Suite struct ClipStoreTests {
    @Test func captureAndReadBack() throws {
        let temp = try TemporaryStore()
        let clip = try temp.add("Hello world")
        #expect(clip.kind == .text)
        #expect(clip.preview == "Hello world")
        #expect(clip.textLength == 11)
        #expect(try temp.store.fullText(clipID: clip.id) == "Hello world")
        let payload = try temp.store.payload(for: clip)
        #expect(payload[0][0].uti == "public.utf8-plain-text")
        #expect(String(decoding: payload[0][0].data, as: UTF8.self) == "Hello world")
    }

    @Test func duplicatesBumpInsteadOfAdding() throws {
        let temp = try TemporaryStore()
        let first = try temp.add("Alpha", at: Date(timeIntervalSince1970: 100))
        try temp.add("Beta", at: Date(timeIntervalSince1970: 200))
        let again = try temp.add("Alpha", at: Date(timeIntervalSince1970: 300))

        #expect(again.id == first.id)
        #expect(again.uuid != first.uuid)
        #expect(again.createdAt == first.createdAt)
        let order = try temp.store.clips(ClipQuery()).map(\.preview)
        #expect(order == ["Alpha", "Beta"])
        #expect(!FileManager.default.fileExists(atPath: temp.directory.appendingPathComponent("blobs/\(first.uuid)").path))
    }

    @Test func recaptureKeepsNewestFormattingAndMetadata() throws {
        let temp = try TemporaryStore()
        let plain = try #require(draft(from: [[utf8Rep("Same words")]]))
        let clip = try temp.store.capture(plain).clip
        try temp.store.rename(clipID: clip.id, title: "Keeper")

        let rich = try #require(draft(from: [[utf8Rep("Same words"), utf8Rep("<b>Same words</b>", type: "public.html")]]))
        let updated = try temp.store.capture(rich).clip
        #expect(updated.title == "Keeper")
        #expect(try temp.store.payload(for: updated)[0].count == 2)
    }

    @Test func searchFindsSubstringsCaseInsensitively() throws {
        let temp = try TemporaryStore()
        try temp.add("The quick brown fox")
        try temp.add("Lazy dog sleeps")
        try temp.add("Quick dog runs")

        #expect(try temp.store.clips(ClipQuery(text: "QUICK")).count == 2)
        #expect(try temp.store.clips(ClipQuery(text: "uic")).count == 2)
        #expect(try temp.store.clips(ClipQuery(text: "quick dog")).map(\.preview) == ["Quick dog runs"])
        #expect(try temp.store.clips(ClipQuery(text: "nothing-here")).isEmpty)
    }

    @Test func searchHandlesShortTokensAndSpecialCharacters() throws {
        let temp = try TemporaryStore()
        try temp.add("go 100% now")
        try temp.add("a_b \"quoted\" value")
        try temp.add("plain words")

        #expect(try temp.store.clips(ClipQuery(text: "go")).count == 1)
        #expect(try temp.store.clips(ClipQuery(text: "%")).map(\.preview) == ["go 100% now"])
        #expect(try temp.store.clips(ClipQuery(text: "_")).map(\.preview) == ["a_b \"quoted\" value"])
        #expect(try temp.store.clips(ClipQuery(text: "\"quoted\"")).count == 1)
        #expect(try temp.store.clips(ClipQuery(text: "AND OR NOT")).isEmpty)
    }

    @Test func searchFindsNonLatinText() throws {
        let temp = try TemporaryStore()
        try temp.add("Merhaba dünya, nasılsın")
        try temp.add("日本語のテキスト")
        #expect(try temp.store.clips(ClipQuery(text: "dünya")).count == 1)
        #expect(try temp.store.clips(ClipQuery(text: "テキスト")).count == 1)
    }

    @Test func searchCoversSourceAppTitleAndOCR() throws {
        let temp = try TemporaryStore()
        let clip = try temp.add("Body words", name: "Safari")
        #expect(try temp.store.clips(ClipQuery(text: "safari")).count == 1)
        try temp.store.rename(clipID: clip.id, title: "Invoice template")
        #expect(try temp.store.clips(ClipQuery(text: "invoice")).count == 1)
        try temp.store.setOCRText("Receipt from the bakery", clipID: clip.id)
        #expect(try temp.store.clips(ClipQuery(text: "bakery")).count == 1)
        #expect(try temp.store.clips(ClipQuery(text: "body")).count == 1)
    }

    @Test func kindFilterAndPaging() throws {
        let temp = try TemporaryStore()
        for index in 0..<5 { try temp.add("Note \(index)", at: Date(timeIntervalSince1970: Double(index))) }
        try temp.add("https://example.com", at: Date(timeIntervalSince1970: 10))

        #expect(try temp.store.clips(ClipQuery(kind: .link)).count == 1)
        let page = try temp.store.clips(ClipQuery(kind: .text, limit: 2, offset: 2))
        #expect(page.map(\.preview) == ["Note 2", "Note 1"])
    }

    @Test func pinboardsGroupClipsAndSurviveDeletion() throws {
        let temp = try TemporaryStore()
        let clip = try temp.add("Pinned", at: Date(timeIntervalSince1970: 1))
        let other = try temp.add("Other", at: Date(timeIntervalSince1970: 2))
        let board = try temp.store.createPinboard(name: "Work", color: "sky")
        try temp.store.pin(clipID: clip.id, pinboardID: board.id)

        #expect(try temp.store.clips(ClipQuery(pinboardID: board.id)).map(\.id) == [clip.id])
        #expect(try temp.store.clip(id: clip.id)?.pinboardIDs == [board.id])
        #expect(try temp.store.clip(id: other.id)?.pinboardIDs == [])
        #expect(try temp.store.clips(ClipQuery(pinnedOnly: true)).map(\.id) == [clip.id])

        try temp.store.deletePinboard(id: board.id)
        #expect(try temp.store.clip(id: clip.id)?.pinboardIDs == [])
        #expect(try temp.store.pinboards().isEmpty)
    }

    @Test func pinboardsKeepCreationOrderAndAcceptRenames() throws {
        let temp = try TemporaryStore()
        let first = try temp.store.createPinboard(name: "One", color: "sky")
        try temp.store.createPinboard(name: "Two", color: "rose")
        try temp.store.updatePinboard(id: first.id, name: "Uno", color: "moss")
        #expect(try temp.store.pinboards().map(\.name) == ["Uno", "Two"])
        #expect(try temp.store.pinboards()[0].color == "moss")
    }

    @Test func pruneSparesPinnedClipsAndRemovesBlobs() throws {
        let temp = try TemporaryStore()
        let old = try temp.add("Old", at: Date(timeIntervalSince1970: 100))
        let pinned = try temp.add("Old but pinned", at: Date(timeIntervalSince1970: 100))
        let recent = try temp.add("Recent", at: Date(timeIntervalSince1970: 500))
        let board = try temp.store.createPinboard(name: "Keep", color: "sky")
        try temp.store.pin(clipID: pinned.id, pinboardID: board.id)

        #expect(try temp.store.prune(before: Date(timeIntervalSince1970: 300)) == 1)
        #expect(try temp.store.clip(id: old.id) == nil)
        #expect(try temp.store.clip(id: pinned.id) != nil)
        #expect(try temp.store.clip(id: recent.id) != nil)
        #expect(!FileManager.default.fileExists(atPath: temp.directory.appendingPathComponent("blobs/\(old.uuid)").path))
    }

    @Test func clearHistoryHonoursKeepPinned() throws {
        let temp = try TemporaryStore()
        let pinned = try temp.add("Pinned")
        try temp.add("Loose")
        let board = try temp.store.createPinboard(name: "Keep", color: "sky")
        try temp.store.pin(clipID: pinned.id, pinboardID: board.id)

        #expect(try temp.store.clearHistory(keepPinned: true) == 1)
        #expect(try temp.store.stats().clipCount == 1)
        #expect(try temp.store.clearHistory(keepPinned: false) == 1)
        #expect(try temp.store.stats().clipCount == 0)
    }

    @Test func kindBreakdownCountsEachKind() throws {
        let temp = try TemporaryStore()
        try temp.add("One note")
        try temp.add("Another note")
        try temp.add("https://example.com")
        let breakdown = try temp.store.kindBreakdown()
        #expect(breakdown.map(\.kind) == [.text, .link])
        #expect(breakdown.map(\.count) == [2, 1])
        #expect(breakdown[0].bytes == 20)
    }

    @Test func deletedClipsLeaveTheSearchIndex() throws {
        let temp = try TemporaryStore()
        let clip = try temp.add("Findable phrase")
        try temp.store.delete(clipID: clip.id)
        #expect(try temp.store.clips(ClipQuery(text: "findable")).isEmpty)
    }

    @Test func recordPasteBumpsAndCounts() throws {
        let temp = try TemporaryStore()
        let older = try temp.add("Older", at: Date(timeIntervalSince1970: 100))
        try temp.add("Newer", at: Date(timeIntervalSince1970: 200))
        try temp.store.recordPaste(clipID: older.id, targetBundleID: "com.example.target", at: Date(timeIntervalSince1970: 300))
        let top = try #require(try temp.store.mostRecentClip())
        #expect(top.id == older.id)
        #expect(top.pasteCount == 1)
    }

    @Test func suggestionsPreferWhatWentToThatApp() throws {
        let temp = try TemporaryStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let weekOld = now.addingTimeInterval(-7 * 86400)
        let used = try temp.add("Pasted into target often", app: "com.other", at: weekOld)
        let fresh = try temp.add("Just copied elsewhere", app: "com.other", at: now.addingTimeInterval(-60))
        try temp.add("Old and unrelated", app: "com.other", at: weekOld)
        let sameApp = try temp.add("Copied from target itself", app: "com.target", at: weekOld)
        try temp.store.recordPaste(clipID: used.id, targetBundleID: "com.target", at: now.addingTimeInterval(-3600))
        try temp.store.recordPaste(clipID: used.id, targetBundleID: "com.target", at: now.addingTimeInterval(-7200))
        try temp.store.recordPaste(clipID: used.id, targetBundleID: "com.elsewhere", at: now.addingTimeInterval(-7200))

        let ranked = try temp.store.suggestions(forApp: "com.target", now: now).map(\.id)
        #expect(ranked.first == used.id)
        #expect(ranked.count == 3)
        #expect(ranked.contains(fresh.id))
        #expect(ranked.contains(sameApp.id))
        #expect(ranked.firstIndex(of: fresh.id)! < ranked.firstIndex(of: sameApp.id)!)
    }

    @Test func sweepRemovesOnlyOrphans() throws {
        let temp = try TemporaryStore()
        let clip = try temp.add("Keep me")
        let orphan = temp.directory.appendingPathComponent("blobs/orphan-folder")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        #expect(try temp.store.sweepOrphans() == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: temp.directory.appendingPathComponent("blobs/\(clip.uuid)").path))
    }

    @Test func dataFolderIsPrivate() throws {
        let temp = try TemporaryStore()
        let attributes = try FileManager.default.attributesOfItem(atPath: temp.directory.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }

    @Test func readOnlyStoreSeesWritesAndRejectsMissingDatabase() throws {
        let temp = try TemporaryStore()
        try temp.add("Shared")
        let reader = try ClipStore(directory: temp.directory, readOnly: true)
        #expect(try reader.clips(ClipQuery()).map(\.preview) == ["Shared"])
        try temp.add("Added later")
        #expect(try reader.clips(ClipQuery()).count == 2)

        let missing = temp.directory.appendingPathComponent("does-not-exist")
        #expect(throws: DatabaseError.self) { try ClipStore(directory: missing, readOnly: true) }
    }
}
