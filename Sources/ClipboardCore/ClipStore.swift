import Foundation

public final class ClipStore: @unchecked Sendable {
    public let directory: URL
    private let db: Database
    private let lock = NSRecursiveLock()
    private let fileManager = FileManager.default
    private var hidesSecretsStorage = true

    private static let databaseName = "history.sqlite"
    private static let previewLength = 1200
    private static let indexedLength = 100_000
    private static let thumbnailName = "thumbnail.png"
    private static let iconName = "icon.png"

    private static let clipColumns = """
        c.id, c.uuid, c.kind, c.title, c.preview, c.text_length, c.source_bundle_id, c.source_name,
        c.created_at, c.sort_at, c.byte_size, c.pixel_width, c.pixel_height, c.item_count, c.paste_count,
        c.link_title, c.has_thumbnail, c.has_icon, c.is_secret,
        (SELECT group_concat(p.pinboard_id) FROM pins p WHERE p.clip_id = c.id) AS pinboard_ids
        """

    /// Masking happens as clips are read, so changing the setting applies to clips already saved.
    public var hidesSecrets: Bool {
        get { locked { hidesSecretsStorage } }
        set { locked { hidesSecretsStorage = newValue } }
    }

    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLIPBOARD_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.bunniesinc.clipboard", isDirectory: true)
    }

    public init(directory: URL = ClipStore.defaultDirectory, readOnly: Bool = false) throws {
        self.directory = directory
        let databasePath = directory.appendingPathComponent(Self.databaseName).path
        if readOnly {
            guard FileManager.default.fileExists(atPath: databasePath) else {
                throw DatabaseError(description: "No clipboard history yet. Open Clipboard and copy something first.")
            }
        } else {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("blobs", isDirectory: true),
                withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        db = try Database(path: databasePath, readOnly: readOnly)
        try db.script("PRAGMA foreign_keys = ON")
        if !readOnly {
            try db.script("PRAGMA journal_mode = WAL")
            try migrate()
        }
    }

    private func migrate() throws {
        let version = try db.query("PRAGMA user_version").first?.int("user_version") ?? 0
        if version < 1 { try createTables() }
        if version < 2 { try addSecretFlag() }
        if version < 3 { try addLinkPreviewColumns() }
        if version < 4 { try addSyncTables() }
    }

    private func addSyncTables() throws {
        try db.transaction {
            try db.script(
                """
                ALTER TABLE clips ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;
                UPDATE clips SET updated_at = created_at;
                CREATE TABLE sync_objects(
                    name TEXT PRIMARY KEY,
                    hash TEXT NOT NULL,
                    version TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX sync_objects_hash ON sync_objects(hash);
                CREATE TABLE sync_deletions(hash TEXT PRIMARY KEY, deleted_at REAL NOT NULL);
                PRAGMA user_version = 4;
                """)
        }
    }

    private func addLinkPreviewColumns() throws {
        try db.transaction {
            try db.script(
                """
                ALTER TABLE clips ADD COLUMN has_icon INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE clips ADD COLUMN link_checked INTEGER NOT NULL DEFAULT 0;
                PRAGMA user_version = 3;
                """)
        }
    }

    private func addSecretFlag() throws {
        try db.transaction {
            try db.script("ALTER TABLE clips ADD COLUMN is_secret INTEGER NOT NULL DEFAULT 0")
            let rows = try db.query("SELECT id, body FROM clips WHERE body IS NOT NULL AND kind != 'file'")
            for row in rows where SecretDetector.containsSecret(row.string("body") ?? "") {
                try db.execute("UPDATE clips SET is_secret = 1 WHERE id = ?", [.int(row.int64("id") ?? 0)])
            }
            try db.script("PRAGMA user_version = 2")
        }
    }

    private func createTables() throws {
        try db.transaction {
            try db.script(
                """
                CREATE TABLE clips(
                    id INTEGER PRIMARY KEY,
                    uuid TEXT NOT NULL UNIQUE,
                    hash TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL,
                    title TEXT,
                    preview TEXT,
                    body TEXT,
                    text_length INTEGER NOT NULL DEFAULT 0,
                    ocr_text TEXT,
                    link_title TEXT,
                    search_text TEXT NOT NULL DEFAULT '',
                    source_bundle_id TEXT,
                    source_name TEXT,
                    created_at REAL NOT NULL,
                    sort_at REAL NOT NULL,
                    byte_size INTEGER NOT NULL,
                    pixel_width INTEGER,
                    pixel_height INTEGER,
                    item_count INTEGER NOT NULL,
                    manifest TEXT NOT NULL,
                    paste_count INTEGER NOT NULL DEFAULT 0,
                    has_thumbnail INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX clips_sort ON clips(sort_at DESC);
                CREATE INDEX clips_kind_sort ON clips(kind, sort_at DESC);
                CREATE INDEX clips_source ON clips(source_bundle_id, sort_at DESC);

                CREATE TABLE pinboards(
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    color TEXT NOT NULL,
                    position INTEGER NOT NULL
                );
                CREATE TABLE pins(
                    pinboard_id INTEGER NOT NULL REFERENCES pinboards(id) ON DELETE CASCADE,
                    clip_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                    pinned_at REAL NOT NULL,
                    PRIMARY KEY(pinboard_id, clip_id)
                );
                CREATE INDEX pins_clip ON pins(clip_id);

                CREATE TABLE paste_events(
                    clip_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                    target_bundle_id TEXT,
                    at REAL NOT NULL
                );
                CREATE INDEX paste_events_target ON paste_events(target_bundle_id, at DESC);
                CREATE INDEX paste_events_clip ON paste_events(clip_id);

                CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);

                CREATE VIRTUAL TABLE clips_fts USING fts5(
                    search_text, content='clips', content_rowid='id', tokenize='trigram'
                );
                CREATE TRIGGER clips_ai AFTER INSERT ON clips BEGIN
                    INSERT INTO clips_fts(rowid, search_text) VALUES (new.id, new.search_text);
                END;
                CREATE TRIGGER clips_ad AFTER DELETE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, search_text) VALUES ('delete', old.id, old.search_text);
                END;
                CREATE TRIGGER clips_au AFTER UPDATE OF search_text ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, search_text) VALUES ('delete', old.id, old.search_text);
                    INSERT INTO clips_fts(rowid, search_text) VALUES (new.id, new.search_text);
                END;

                PRAGMA user_version = 1;
                """)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func blobDirectory(_ uuid: String) -> URL {
        directory.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent(uuid, isDirectory: true)
    }

    public func thumbnailURL(for clip: Clip) -> URL? {
        clip.hasThumbnail ? blobDirectory(clip.uuid).appendingPathComponent(Self.thumbnailName) : nil
    }

    public func iconURL(for clip: Clip) -> URL? {
        clip.hasIcon ? blobDirectory(clip.uuid).appendingPathComponent(Self.iconName) : nil
    }

    // MARK: Capture

    private struct ManifestEntry: Codable {
        let uti: String
        let file: String
    }

    @discardableResult
    public func capture(_ draft: ClipDraft, at now: Date = Date()) throws -> CaptureResult {
        try locked {
            let existing = try db.query(
                "SELECT id, uuid, has_thumbnail, has_icon, title, ocr_text, link_title FROM clips WHERE hash = ?",
                [.text(draft.hash)]
            ).first

            let uuid = UUID().uuidString
            let folder = blobDirectory(uuid)
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                var manifest: [[ManifestEntry]] = []
                for (itemIndex, reps) in draft.items.enumerated() {
                    var entries: [ManifestEntry] = []
                    for (repIndex, rep) in reps.enumerated() {
                        let name = "\(itemIndex)-\(repIndex)"
                        try rep.data.write(to: folder.appendingPathComponent(name))
                        entries.append(ManifestEntry(uti: rep.uti, file: name))
                    }
                    manifest.append(entries)
                }
                if let thumbnail = draft.thumbnail {
                    try thumbnail.write(to: folder.appendingPathComponent(Self.thumbnailName))
                }
                let manifestJSON = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)

                let id: Int64
                if let existing, let existingID = existing.int64("id"), let oldUUID = existing.string("uuid") {
                    var hasThumbnail = draft.thumbnail != nil
                    if !hasThumbnail, existing.int("has_thumbnail") == 1 {
                        try? fileManager.moveItem(
                            at: blobDirectory(oldUUID).appendingPathComponent(Self.thumbnailName),
                            to: folder.appendingPathComponent(Self.thumbnailName))
                        hasThumbnail = true
                    }
                    if existing.int("has_icon") == 1 {
                        try? fileManager.moveItem(
                            at: blobDirectory(oldUUID).appendingPathComponent(Self.iconName),
                            to: folder.appendingPathComponent(Self.iconName))
                    }
                    let search = Self.searchText(
                        title: existing.string("title"), body: draft.text, ocr: existing.string("ocr_text"),
                        linkTitle: existing.string("link_title"), sourceName: draft.source.name)
                    try db.execute(
                        """
                        UPDATE clips SET uuid = ?, kind = ?, preview = ?, body = ?, text_length = ?, search_text = ?,
                            source_bundle_id = ?, source_name = ?, sort_at = ?, byte_size = ?, pixel_width = ?,
                            pixel_height = ?, item_count = ?, manifest = ?, has_thumbnail = ?, is_secret = ?
                        WHERE id = ?
                        """,
                        [
                            .text(uuid), .text(draft.kind.rawValue), .optional(Self.preview(draft.text)),
                            .optional(draft.text), .int(Int64(draft.text?.count ?? 0)), .text(search),
                            .optional(draft.source.bundleID), .optional(draft.source.name),
                            .real(now.timeIntervalSince1970), .int(draft.byteSize), .optional(draft.pixelWidth),
                            .optional(draft.pixelHeight), .int(Int64(draft.items.count)), .text(manifestJSON),
                            .int(hasThumbnail ? 1 : 0), .int(draft.isSecret ? 1 : 0), .int(existingID),
                        ])
                    try? fileManager.removeItem(at: blobDirectory(oldUUID))
                    id = existingID
                } else {
                    let search = Self.searchText(
                        title: nil, body: draft.text, ocr: nil, linkTitle: nil, sourceName: draft.source.name)
                    try db.execute(
                        """
                        INSERT INTO clips(uuid, hash, kind, preview, body, text_length, search_text, source_bundle_id,
                            source_name, created_at, sort_at, byte_size, pixel_width, pixel_height, item_count,
                            manifest, has_thumbnail, is_secret, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(uuid), .text(draft.hash), .text(draft.kind.rawValue),
                            .optional(Self.preview(draft.text)), .optional(draft.text),
                            .int(Int64(draft.text?.count ?? 0)), .text(search), .optional(draft.source.bundleID),
                            .optional(draft.source.name), .real(now.timeIntervalSince1970),
                            .real(now.timeIntervalSince1970), .int(draft.byteSize), .optional(draft.pixelWidth),
                            .optional(draft.pixelHeight), .int(Int64(draft.items.count)), .text(manifestJSON),
                            .int(draft.thumbnail != nil ? 1 : 0), .int(draft.isSecret ? 1 : 0),
                            .real(now.timeIntervalSince1970),
                        ])
                    id = db.lastInsertID
                }
                try db.execute("DELETE FROM sync_deletions WHERE hash = ?", [.text(draft.hash)])
                guard let clip = try clip(id: id) else {
                    throw DatabaseError(description: "Clip \(id) disappeared after saving")
                }
                return CaptureResult(clip: clip, isNew: existing == nil)
            } catch {
                try? fileManager.removeItem(at: folder)
                throw error
            }
        }
    }

    private static func preview(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.drop(while: \.isNewline)
        return String(trimmed.prefix(previewLength))
    }

    private static func searchText(
        title: String?, body: String?, ocr: String?, linkTitle: String?, sourceName: String?
    ) -> String {
        [title, body.map { String($0.prefix(indexedLength)) }, ocr, linkTitle, sourceName]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func refreshSearchText(clipID: Int64) throws {
        guard
            let row = try db.query(
                "SELECT title, body, ocr_text, link_title, source_name FROM clips WHERE id = ?", [.int(clipID)]
            ).first
        else { return }
        let search = Self.searchText(
            title: row.string("title"), body: row.string("body"), ocr: row.string("ocr_text"),
            linkTitle: row.string("link_title"), sourceName: row.string("source_name"))
        try db.execute("UPDATE clips SET search_text = ? WHERE id = ?", [.text(search), .int(clipID)])
    }

    public func setOCRText(_ text: String, clipID: Int64) throws {
        try locked {
            try db.execute("UPDATE clips SET ocr_text = ? WHERE id = ?", [.text(text), .int(clipID)])
            try refreshSearchText(clipID: clipID)
        }
    }

    /// Marks the link as tried, so nothing here visits it again. Whatever a fetch didn't find keeps its old value.
    public func setLinkMetadata(title: String?, thumbnail: Data?, icon: Data? = nil, clipID: Int64) throws {
        try locked {
            guard let row = try db.query("SELECT uuid FROM clips WHERE id = ?", [.int(clipID)]).first,
                let uuid = row.string("uuid")
            else { return }
            if let thumbnail {
                try thumbnail.write(to: blobDirectory(uuid).appendingPathComponent(Self.thumbnailName))
                try db.execute("UPDATE clips SET has_thumbnail = 1 WHERE id = ?", [.int(clipID)])
            }
            if let icon {
                try icon.write(to: blobDirectory(uuid).appendingPathComponent(Self.iconName))
                try db.execute("UPDATE clips SET has_icon = 1 WHERE id = ?", [.int(clipID)])
            }
            try db.execute(
                "UPDATE clips SET link_title = COALESCE(?, link_title), link_checked = 1 WHERE id = ?",
                [.optional(title), .int(clipID)])
            try refreshSearchText(clipID: clipID)
        }
    }

    /// Links nothing has tried to fetch yet, newest first. Secrets stay out, since visiting one would hand it to the site.
    public func linksMissingPreview(since cutoff: Date, limit: Int = 30) throws -> [Clip] {
        try locked {
            try db.query(
                """
                SELECT \(Self.clipColumns) FROM clips c
                WHERE c.kind = 'link' AND c.link_checked = 0 AND c.is_secret = 0 AND c.sort_at >= ?
                ORDER BY c.sort_at DESC LIMIT ?
                """,
                [.real(cutoff.timeIntervalSince1970), .int(Int64(limit))]
            ).compactMap(makeClip)
        }
    }

    // MARK: Reading

    private func makeClip(_ row: Row) -> Clip? {
        guard let id = row.int64("id"), let uuid = row.string("uuid"),
            let kind = row.string("kind").flatMap(ClipKind.init(rawValue:)),
            let created = row.double("created_at"), let sorted = row.double("sort_at")
        else { return nil }
        let isSecret = row.int("is_secret") == 1
        let isHidden = isSecret && hidesSecretsStorage
        return Clip(
            id: id, uuid: uuid, kind: kind, title: row.string("title"),
            preview: isHidden ? Clip.hiddenPreview : row.string("preview"),
            textLength: row.int("text_length") ?? 0,
            source: ClipSource(bundleID: row.string("source_bundle_id"), name: row.string("source_name")),
            createdAt: Date(timeIntervalSince1970: created), sortedAt: Date(timeIntervalSince1970: sorted),
            byteSize: row.int64("byte_size") ?? 0, pixelWidth: row.int("pixel_width"),
            pixelHeight: row.int("pixel_height"), itemCount: row.int("item_count") ?? 1,
            pasteCount: row.int("paste_count") ?? 0, linkTitle: isHidden ? nil : row.string("link_title"),
            hasThumbnail: row.int("has_thumbnail") == 1, hasIcon: !isHidden && row.int("has_icon") == 1,
            pinboardIDs: row.string("pinboard_ids")?.split(separator: ",").compactMap { Int64($0) } ?? [],
            isSecret: isSecret, isHidden: isHidden)
    }

    public func clip(id: Int64) throws -> Clip? {
        try locked {
            try db.query("SELECT \(Self.clipColumns) FROM clips c WHERE c.id = ?", [.int(id)]).first.flatMap(makeClip)
        }
    }

    public func clips(_ query: ClipQuery) throws -> [Clip] {
        try locked {
            var sql = "SELECT \(Self.clipColumns) FROM clips c"
            var params: [SQLValue] = []
            var conditions: [String] = []

            if let board = query.pinboardID {
                sql += " JOIN pins pin ON pin.clip_id = c.id AND pin.pinboard_id = ?"
                params.append(.int(board))
            }
            if let kind = query.kind {
                conditions.append("c.kind = ?")
                params.append(.text(kind.rawValue))
            }
            if query.pinnedOnly {
                conditions.append("EXISTS (SELECT 1 FROM pins x WHERE x.clip_id = c.id)")
            }
            if query.excludesSecrets { conditions.append("c.is_secret = 0") }
            for token in query.text.split(whereSeparator: \.isWhitespace).map(String.init) {
                // The trigram tokenizer can't index anything shorter than three characters.
                if token.unicodeScalars.count >= 3 {
                    conditions.append("c.id IN (SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?)")
                    params.append(.text("\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""))
                } else {
                    let escaped = token
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "%", with: "\\%")
                        .replacingOccurrences(of: "_", with: "\\_")
                    conditions.append("c.search_text LIKE ? ESCAPE '\\'")
                    params.append(.text("%" + escaped + "%"))
                }
            }
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            sql += query.pinboardID != nil ? " ORDER BY pin.pinned_at DESC" : " ORDER BY c.sort_at DESC"
            sql += " LIMIT ? OFFSET ?"
            params.append(.int(Int64(query.limit)))
            params.append(.int(Int64(query.offset)))
            return try db.query(sql, params).compactMap(makeClip)
        }
    }

    /// Ranks what's likely to be pasted next into `bundleID`: what went there before, then what was just
    /// copied elsewhere and hasn't landed yet, then what came from the same app.
    public func suggestions(forApp bundleID: String?, limit: Int = 48, now: Date = Date()) throws -> [Clip] {
        let time = now.timeIntervalSince1970
        return try locked {
            let sql = """
                SELECT \(Self.clipColumns) FROM clips c JOIN (
                    SELECT clip_id, SUM(score) AS score FROM (
                        SELECT clip_id, 1.0 / (1.0 + (?1 - at) / 86400.0) AS score
                            FROM paste_events WHERE target_bundle_id IS ?2
                        UNION ALL
                        SELECT id AS clip_id, 0.5 * (1.0 - (?1 - sort_at) / 3600.0) AS score
                            FROM clips WHERE sort_at > ?1 - 3600.0 AND source_bundle_id IS NOT ?2
                        UNION ALL
                        SELECT id AS clip_id, 0.25 / (1.0 + (?1 - sort_at) / 86400.0) AS score
                            FROM clips WHERE source_bundle_id IS ?2
                    ) GROUP BY clip_id
                ) ranked ON ranked.clip_id = c.id
                ORDER BY ranked.score DESC, c.sort_at DESC LIMIT ?3
                """
            return try db.query(sql, [.real(time), .optional(bundleID), .int(Int64(limit))]).compactMap(makeClip)
        }
    }

    public func fullText(clipID: Int64) throws -> String? {
        try locked {
            try db.query("SELECT body FROM clips WHERE id = ?", [.int(clipID)]).first?.string("body")
        }
    }

    public func payload(for clip: Clip) throws -> [[Representation]] {
        let manifest: String? = try locked {
            try db.query("SELECT manifest FROM clips WHERE id = ?", [.int(clip.id)]).first?.string("manifest")
        }
        guard let manifest else { throw DatabaseError(description: "Clip \(clip.id) no longer exists") }
        let entries = try JSONDecoder().decode([[ManifestEntry]].self, from: Data(manifest.utf8))
        let folder = blobDirectory(clip.uuid)
        return try entries.map { item in
            try item.map { Representation(uti: $0.uti, data: try Data(contentsOf: folder.appendingPathComponent($0.file))) }
        }
    }

    public func stats() throws -> StoreStats {
        try locked {
            let row = try db.query("SELECT count(*) AS total, COALESCE(sum(byte_size), 0) AS bytes FROM clips").first
            return StoreStats(clipCount: row?.int("total") ?? 0, totalBytes: row?.int64("bytes") ?? 0)
        }
    }

    public func kindBreakdown() throws -> [KindBreakdown] {
        try locked {
            try db.query(
                "SELECT kind, count(*) AS total, COALESCE(sum(byte_size), 0) AS bytes FROM clips GROUP BY kind ORDER BY total DESC"
            ).compactMap { row in
                guard let kind = row.string("kind").flatMap(ClipKind.init(rawValue:)) else { return nil }
                return KindBreakdown(kind: kind, count: row.int("total") ?? 0, bytes: row.int64("bytes") ?? 0)
            }
        }
    }

    public func mostRecentClip() throws -> Clip? {
        try clips(ClipQuery(limit: 1)).first
    }

    // MARK: Editing

    public func rename(clipID: Int64, title: String?) throws {
        try locked {
            let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            try db.execute(
                "UPDATE clips SET title = ?, updated_at = ? WHERE id = ?",
                [.optional(cleaned?.isEmpty == true ? nil : cleaned), .real(Date().timeIntervalSince1970), .int(clipID)])
            try refreshSearchText(clipID: clipID)
        }
    }

    public func recordPaste(clipID: Int64, targetBundleID: String?, at now: Date = Date()) throws {
        try locked {
            try db.transaction {
                try db.execute(
                    "INSERT INTO paste_events(clip_id, target_bundle_id, at) VALUES (?, ?, ?)",
                    [.int(clipID), .optional(targetBundleID), .real(now.timeIntervalSince1970)])
                try db.execute(
                    "UPDATE clips SET paste_count = paste_count + 1, sort_at = ? WHERE id = ?",
                    [.real(now.timeIntervalSince1970), .int(clipID)])
            }
        }
    }

    #if DEBUG
    public func setSortDateForDemo(clipID: Int64, date: Date) throws {
        try locked {
            try db.execute("UPDATE clips SET sort_at = ? WHERE id = ?", [.real(date.timeIntervalSince1970), .int(clipID)])
        }
    }
    #endif

    public func delete(clipID: Int64) throws {
        try locked {
            try db.execute(
                """
                INSERT OR REPLACE INTO sync_deletions(hash, deleted_at)
                SELECT DISTINCT c.hash, ? FROM clips c JOIN sync_objects o ON o.hash = c.hash WHERE c.id = ?
                """,
                [.real(Date().timeIntervalSince1970), .int(clipID)])
            let uuid = try db.query("SELECT uuid FROM clips WHERE id = ?", [.int(clipID)]).first?.string("uuid")
            try db.execute("DELETE FROM clips WHERE id = ?", [.int(clipID)])
            if let uuid { try? fileManager.removeItem(at: blobDirectory(uuid)) }
        }
    }

    private func deleteClips(where condition: String, _ params: [SQLValue] = []) throws -> Int {
        let uuids = try db.query("SELECT uuid FROM clips WHERE \(condition)", params).compactMap { $0.string("uuid") }
        try db.execute("DELETE FROM clips WHERE \(condition)", params)
        for uuid in uuids { try? fileManager.removeItem(at: blobDirectory(uuid)) }
        return uuids.count
    }

    @discardableResult
    public func clearHistory(keepPinned: Bool) throws -> Int {
        try locked {
            let condition = keepPinned ? "NOT EXISTS (SELECT 1 FROM pins WHERE pins.clip_id = clips.id)" : "1 = 1"
            // Otherwise the next sync would bring everything straight back.
            try db.execute(
                """
                INSERT OR REPLACE INTO sync_deletions(hash, deleted_at)
                SELECT DISTINCT clips.hash, ? FROM clips JOIN sync_objects o ON o.hash = clips.hash WHERE \(condition)
                """,
                [.real(Date().timeIntervalSince1970)])
            let removed = try deleteClips(where: condition)
            try db.script("PRAGMA wal_checkpoint(TRUNCATE)")
            return removed
        }
    }

    /// Pinned clips are kept forever; retention only applies to plain history.
    @discardableResult
    public func prune(before cutoff: Date) throws -> Int {
        try locked {
            try deleteClips(
                where: "sort_at < ? AND NOT EXISTS (SELECT 1 FROM pins WHERE pins.clip_id = clips.id)",
                [.real(cutoff.timeIntervalSince1970)])
        }
    }

    /// Drops blob folders left behind by a crash between writing files and committing the row.
    @discardableResult
    public func sweepOrphans() throws -> Int {
        try locked {
            let known = Set(try db.query("SELECT uuid FROM clips").compactMap { $0.string("uuid") })
            let root = directory.appendingPathComponent("blobs", isDirectory: true)
            let folders = try fileManager.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }
            let orphans = folders.filter { !known.contains($0) }
            for orphan in orphans { try? fileManager.removeItem(at: root.appendingPathComponent(orphan)) }
            return orphans.count
        }
    }

    public func trimPasteEvents(before cutoff: Date) throws {
        try locked {
            try db.execute("DELETE FROM paste_events WHERE at < ?", [.real(cutoff.timeIntervalSince1970)])
        }
    }

    // MARK: Pinboards

    public func pinboards() throws -> [Pinboard] {
        try locked {
            try db.query("SELECT id, name, color, position FROM pinboards ORDER BY position, id").compactMap { row in
                guard let id = row.int64("id"), let name = row.string("name"), let color = row.string("color") else {
                    return nil
                }
                return Pinboard(id: id, name: name, color: color, position: row.int("position") ?? 0)
            }
        }
    }

    @discardableResult
    public func createPinboard(name: String, color: String) throws -> Pinboard {
        try locked {
            let next = try db.query("SELECT COALESCE(MAX(position), -1) + 1 AS next FROM pinboards").first?.int("next") ?? 0
            try db.execute(
                "INSERT INTO pinboards(name, color, position) VALUES (?, ?, ?)",
                [.text(name), .text(color), .int(Int64(next))])
            return Pinboard(id: db.lastInsertID, name: name, color: color, position: next)
        }
    }

    public func updatePinboard(id: Int64, name: String, color: String) throws {
        try locked {
            try db.execute("UPDATE pinboards SET name = ?, color = ? WHERE id = ?", [.text(name), .text(color), .int(id)])
            try touchClips(onBoard: id)
        }
    }

    public func deletePinboard(id: Int64) throws {
        try locked {
            try touchClips(onBoard: id)
            try db.execute("DELETE FROM pinboards WHERE id = ?", [.int(id)])
        }
    }

    // Each clip carries its boards by name, so a change to a board is a change to every clip on it.
    private func touchClips(onBoard id: Int64) throws {
        try db.execute(
            "UPDATE clips SET updated_at = ? WHERE id IN (SELECT clip_id FROM pins WHERE pinboard_id = ?)",
            [.real(Date().timeIntervalSince1970), .int(id)])
    }

    public func pin(clipID: Int64, pinboardID: Int64, at now: Date = Date()) throws {
        try locked {
            try db.execute(
                "INSERT OR REPLACE INTO pins(pinboard_id, clip_id, pinned_at) VALUES (?, ?, ?)",
                [.int(pinboardID), .int(clipID), .real(now.timeIntervalSince1970)])
            try db.execute("UPDATE clips SET updated_at = ? WHERE id = ?", [.real(now.timeIntervalSince1970), .int(clipID)])
        }
    }

    public func unpin(clipID: Int64, pinboardID: Int64) throws {
        try locked {
            try db.execute("DELETE FROM pins WHERE pinboard_id = ? AND clip_id = ?", [.int(pinboardID), .int(clipID)])
            try db.execute("UPDATE clips SET updated_at = ? WHERE id = ?", [.real(Date().timeIntervalSince1970), .int(clipID)])
        }
    }

    // MARK: Sync

    struct SyncCandidate {
        let clip: Clip
        let hash: String
        let updatedAt: Double
        let boards: [Pinboard]
    }

    /// Clips with changes to send, newest first. Files mean nothing on another device, and secrets never leave this one.
    func syncCandidates(limit: Int, largest: Int64) throws -> [SyncCandidate] {
        try locked {
            let rows = try db.query(
                """
                SELECT \(Self.clipColumns), c.hash AS sync_hash, c.updated_at AS sync_updated_at
                FROM clips c LEFT JOIN sync_objects o ON o.hash = c.hash AND o.name LIKE '%.clip'
                WHERE c.kind != 'file' AND c.is_secret = 0 AND c.byte_size <= ?
                    AND (o.hash IS NULL OR o.updated_at < c.updated_at)
                ORDER BY c.sort_at DESC LIMIT ?
                """,
                [.int(largest), .int(Int64(limit))])
            let boards = try pinboards()
            return rows.compactMap { row in
                guard let clip = makeClip(row), let hash = row.string("sync_hash") else { return nil }
                return SyncCandidate(
                    clip: clip, hash: hash, updatedAt: row.double("sync_updated_at") ?? 0,
                    boards: boards.filter { clip.pinboardIDs.contains($0.id) })
            }
        }
    }

    func syncedVersions() throws -> [String: String] {
        try locked {
            var versions: [String: String] = [:]
            for row in try db.query("SELECT name, version FROM sync_objects") {
                if let name = row.string("name"), let version = row.string("version") { versions[name] = version }
            }
            return versions
        }
    }

    func recordSyncedObject(name: String, hash: String, version: String, updatedAt: Double) throws {
        try locked {
            try db.execute(
                "INSERT OR REPLACE INTO sync_objects(name, hash, version, updated_at) VALUES (?, ?, ?, ?)",
                [.text(name), .text(hash), .text(version), .real(updatedAt)])
        }
    }

    /// Whatever vanished from the cloud gets uploaded again if this device still has the clip.
    func forgetSyncedObjects(notIn names: Set<String>) throws {
        try locked {
            for name in try syncedVersions().keys where !names.contains(name) {
                try db.execute("DELETE FROM sync_objects WHERE name = ?", [.text(name)])
            }
        }
    }

    func syncLocalState(hash: String) throws -> (id: Int64, updatedAt: Double)? {
        try locked {
            guard let row = try db.query("SELECT id, updated_at FROM clips WHERE hash = ?", [.text(hash)]).first,
                let id = row.int64("id")
            else { return nil }
            return (id, row.double("updated_at") ?? 0)
        }
    }

    /// Removes a clip another device deleted, without recording a deletion of its own to send back.
    func deleteSyncedClip(id: Int64) throws {
        try locked {
            let uuid = try db.query("SELECT uuid FROM clips WHERE id = ?", [.int(id)]).first?.string("uuid")
            try db.execute("DELETE FROM clips WHERE id = ?", [.int(id)])
            if let uuid { try? fileManager.removeItem(at: blobDirectory(uuid)) }
        }
    }

    func applySyncedChanges(
        clipID: Int64, title: String?, pinboards boards: [(name: String, color: String)], updatedAt: Double, sortedAt: Date?
    ) throws {
        try locked {
            try db.execute("UPDATE clips SET title = ?, updated_at = ? WHERE id = ?", [.optional(title), .real(updatedAt), .int(clipID)])
            if let sortedAt {
                try db.execute(
                    "UPDATE clips SET sort_at = MAX(sort_at, ?) WHERE id = ?", [.real(sortedAt.timeIntervalSince1970), .int(clipID)])
            }
            try refreshSearchText(clipID: clipID)
            try setSyncedPins(clipID: clipID, boards: boards)
        }
    }

    func finishSyncedCapture(
        clipID: Int64, createdAt: Date?, title: String?, pinboards boards: [(name: String, color: String)], updatedAt: Double
    ) throws {
        try locked {
            try db.execute(
                "UPDATE clips SET title = ?, updated_at = ?, created_at = COALESCE(?, created_at) WHERE id = ?",
                [.optional(title), .real(updatedAt), createdAt.map { .real($0.timeIntervalSince1970) } ?? .null, .int(clipID)])
            try refreshSearchText(clipID: clipID)
            try setSyncedPins(clipID: clipID, boards: boards)
        }
    }

    private func setSyncedPins(clipID: Int64, boards: [(name: String, color: String)]) throws {
        try db.execute("DELETE FROM pins WHERE clip_id = ?", [.int(clipID)])
        let existing = try pinboards()
        for board in boards {
            let id = try existing.first { $0.name == board.name }?.id ?? createPinboard(name: board.name, color: board.color).id
            try db.execute(
                "INSERT OR REPLACE INTO pins(pinboard_id, clip_id, pinned_at) VALUES (?, ?, ?)",
                [.int(id), .int(clipID), .real(Date().timeIntervalSince1970)])
        }
    }

    func pendingSyncDeletions() throws -> [(hash: String, deletedAt: Double)] {
        try locked {
            try db.query("SELECT hash, deleted_at FROM sync_deletions ORDER BY deleted_at DESC").compactMap { row in
                guard let hash = row.string("hash"), let deletedAt = row.double("deleted_at") else { return nil }
                return (hash, deletedAt)
            }
        }
    }

    func pendingSyncDeletion(hash: String) throws -> Double? {
        try locked {
            try db.query("SELECT deleted_at FROM sync_deletions WHERE hash = ?", [.text(hash)]).first?.double("deleted_at")
        }
    }

    func finishSyncDeletion(hash: String) throws {
        try locked { try db.execute("DELETE FROM sync_deletions WHERE hash = ?", [.text(hash)]) }
    }

    /// For switching where clips sync to, since nothing recorded here is true of the new place.
    public func resetSyncState() throws {
        try locked {
            try db.script("DELETE FROM sync_objects; DELETE FROM sync_deletions;")
        }
    }

    // MARK: Settings shared with the MCP helper

    public func aiAccess() throws -> AIAccess {
        try locked {
            let value = try db.query("SELECT value FROM settings WHERE key = 'ai_access'").first?.string("value")
            return value.flatMap(AIAccess.init(rawValue:)) ?? .off
        }
    }

    public func setAIAccess(_ access: AIAccess) throws {
        try locked {
            try db.execute(
                "INSERT INTO settings(key, value) VALUES ('ai_access', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(access.rawValue)])
        }
    }
}
