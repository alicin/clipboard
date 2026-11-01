import Foundation

public struct SyncObject: Sendable, Equatable {
    public let name: String
    /// Changes whenever the contents do.
    public let version: String
    public let modified: Date

    public init(name: String, version: String, modified: Date) {
        self.name = name
        self.version = version
        self.modified = modified
    }
}

public protocol SyncBackend: Sendable {
    func list() async throws -> [SyncObject]
    func read(_ name: String) async throws -> Data
    /// Returns the object's new version.
    func write(_ name: String, data: Data) async throws -> String
    func delete(_ name: String) async throws
}

/// Any folder a sync service watches. Files stay whole and are never edited in place, because the service may upload one
/// at any moment. A database can't go here: copying a live SQLite file between devices corrupts it.
public struct FolderSyncBackend: SyncBackend {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func list() async throws -> [SyncObject] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles)
        return try urls.map { url in
            let (version, modified) = try Self.version(of: url)
            return SyncObject(name: url.lastPathComponent, version: version, modified: modified)
        }
    }

    public func read(_ name: String) async throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    public func write(_ name: String, data: Data) async throws -> String {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return try Self.version(of: url).0
    }

    public func delete(_ name: String) async throws {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    private static func version(of url: URL) throws -> (String, Date) {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values.contentModificationDate ?? .distantPast
        return ("\(modified.timeIntervalSince1970)-\(values.fileSize ?? 0)", modified)
    }
}

/// One clip in the shared format every device reads and writes. See docs/sync-format.md.
struct SyncRecord: Codable {
    struct Item: Codable {
        let uti: String
        let data: Data
    }

    struct Board: Codable {
        let name: String
        let color: String
    }

    var format = 1
    let hash: String
    let updatedAt: Double
    var deletedAt: Double?
    var createdAt: Double?
    var sortedAt: Double?
    var title: String?
    var sourceBundleID: String?
    var sourceName: String?
    var pinboards: [Board]?
    var items: [[Item]]?
}

public actor SyncEngine {
    public struct Report: Sendable {
        public var uploaded = 0
        public var downloaded = 0
        public var deleted = 0
        public var arrived: [CaptureResult] = []
        public var hasMoreWork = false
    }

    /// A file on one Mac means nothing on another, and a very large clip would eat the user's cloud storage.
    public static let largestClip: Int64 = 25_000_000
    private static let clipSuffix = ".clip"
    private static let goneSuffix = ".gone"
    // A device that stays offline longer than this can bring a deleted clip back, which beats the list growing forever.
    private static let goneLifetime: TimeInterval = 30 * 86400

    private let store: ClipStore
    private let backend: any SyncBackend
    private let keys: SyncKeys
    private let batch: Int
    private var checkedInfoVersion: String?

    public init(store: ClipStore, backend: any SyncBackend, keys: SyncKeys, batch: Int = 100) {
        self.store = store
        self.backend = backend
        self.keys = keys
        self.batch = batch
    }

    /// Pulls before pushing, so the newest change to a clip wins whichever device made it. Each pass handles one batch.
    public func run(keepingOnlyAfter cutoff: Date? = nil, now: Date = Date()) async throws -> Report {
        let objects = try await backend.list()
        try await checkKeys(against: objects)

        var report = Report()
        try await pull(objects, cutoff: cutoff, report: &report)
        var kept = Set(objects.map(\.name))
        kept.formUnion(try await pushDeletions(objects, report: &report))
        kept.formUnion(try await pushClips(objects, report: &report))
        try store.forgetSyncedObjects(notIn: kept)

        for object in objects where object.name.hasSuffix(Self.goneSuffix) {
            if now.timeIntervalSince(object.modified) > Self.goneLifetime { try await backend.delete(object.name) }
        }
        return report
    }

    private func checkKeys(against objects: [SyncObject]) async throws {
        guard let info = objects.first(where: { $0.name == SyncKeys.infoName }) else { throw SyncError.wrongPassphrase }
        guard info.version != checkedInfoVersion else { return }
        guard keys.matchesInfo(try await backend.read(info.name)) else { throw SyncError.wrongPassphrase }
        checkedInfoVersion = info.version
    }

    private func pull(_ objects: [SyncObject], cutoff: Date?, report: inout Report) async throws {
        let known = try store.syncedVersions()
        let incoming = objects
            .filter { $0.name.hasSuffix(Self.clipSuffix) || $0.name.hasSuffix(Self.goneSuffix) }
            .filter { known[$0.name] != $0.version }
            .sorted { $0.modified > $1.modified }
        if incoming.count > batch { report.hasMoreWork = true }

        for object in incoming.prefix(batch) {
            let sealed = try await backend.read(object.name)
            guard let plain = try? keys.open(sealed) else { throw SyncError.wrongPassphrase }
            // A newer client's format isn't ours to guess at. The row below keeps it from being read again each pass.
            if let record = try? JSONDecoder().decode(SyncRecord.self, from: plain), record.format == 1 {
                try apply(record, cutoff: cutoff, report: &report)
                try store.recordSyncedObject(name: object.name, hash: record.hash, version: object.version, updatedAt: record.updatedAt)
            } else {
                try store.recordSyncedObject(name: object.name, hash: "", version: object.version, updatedAt: 0)
            }
        }
    }

    private func apply(_ record: SyncRecord, cutoff: Date?, report: inout Report) throws {
        let local = try store.syncLocalState(hash: record.hash)
        if let deletedAt = record.deletedAt {
            if let local, local.updatedAt <= deletedAt {
                try store.deleteSyncedClip(id: local.id)
                report.deleted += 1
            }
            return
        }
        let boards = (record.pinboards ?? []).map { (name: $0.name, color: $0.color) }
        if let local {
            if record.updatedAt > local.updatedAt {
                try store.applySyncedChanges(
                    clipID: local.id, title: record.title, pinboards: boards, updatedAt: record.updatedAt,
                    sortedAt: record.sortedAt.map(Date.init(timeIntervalSince1970:)))
                report.downloaded += 1
            }
            return
        }
        // Past this device's retention, and retention never touches pinned clips.
        if let cutoff, boards.isEmpty, let sortedAt = record.sortedAt, sortedAt < cutoff.timeIntervalSince1970 { return }
        // A local deletion newer than this copy wins, and the push that follows tells everyone else.
        if let deletedAt = try store.pendingSyncDeletion(hash: record.hash), deletedAt >= record.updatedAt { return }

        let items = (record.items ?? []).map { $0.map { Representation(uti: $0.uti, data: $0.data) } }
        let source = ClipSource(bundleID: record.sourceBundleID, name: record.sourceName)
        guard case .clip(let draft) = ClipBuilder.build(items: items, source: source, secrets: .skip) else { return }
        let result = try store.capture(draft, at: Date(timeIntervalSince1970: record.sortedAt ?? record.updatedAt))
        try store.finishSyncedCapture(
            clipID: result.clip.id, createdAt: record.createdAt.map(Date.init(timeIntervalSince1970:)), title: record.title,
            pinboards: boards, updatedAt: record.updatedAt)
        if let clip = try store.clip(id: result.clip.id) {
            report.arrived.append(CaptureResult(clip: clip, isNew: true))
        }
        report.downloaded += 1
    }

    private func pushDeletions(_ objects: [SyncObject], report: inout Report) async throws -> [String] {
        var written: [String] = []
        let pending = try store.pendingSyncDeletions()
        if pending.count > batch { report.hasMoreWork = true }
        for deletion in pending.prefix(batch) {
            let name = keys.objectName(forHash: deletion.hash)
            let record = SyncRecord(hash: deletion.hash, updatedAt: deletion.deletedAt, deletedAt: deletion.deletedAt)
            let goneName = name + Self.goneSuffix
            let version = try await backend.write(goneName, data: try keys.seal(try JSONEncoder().encode(record)))
            try store.recordSyncedObject(name: goneName, hash: deletion.hash, version: version, updatedAt: deletion.deletedAt)
            if objects.contains(where: { $0.name == name + Self.clipSuffix }) { try await backend.delete(name + Self.clipSuffix) }
            try store.finishSyncDeletion(hash: deletion.hash)
            written.append(goneName)
        }
        return written
    }

    private func pushClips(_ objects: [SyncObject], report: inout Report) async throws -> [String] {
        var written: [String] = []
        let candidates = try store.syncCandidates(limit: batch + 1, largest: Self.largestClip)
        if candidates.count > batch { report.hasMoreWork = true }
        for candidate in candidates.prefix(batch) {
            guard let payload = try? store.payload(for: candidate.clip) else { continue }
            let record = SyncRecord(
                hash: candidate.hash, updatedAt: candidate.updatedAt, createdAt: candidate.clip.createdAt.timeIntervalSince1970,
                sortedAt: candidate.clip.sortedAt.timeIntervalSince1970, title: candidate.clip.title,
                sourceBundleID: candidate.clip.source.bundleID, sourceName: candidate.clip.source.name,
                pinboards: candidate.boards.map { SyncRecord.Board(name: $0.name, color: $0.color) },
                items: payload.map { $0.map { SyncRecord.Item(uti: $0.uti, data: $0.data) } })
            let name = keys.objectName(forHash: candidate.hash)
            let version = try await backend.write(name + Self.clipSuffix, data: try keys.seal(try JSONEncoder().encode(record)))
            try store.recordSyncedObject(name: name + Self.clipSuffix, hash: candidate.hash, version: version, updatedAt: candidate.updatedAt)
            if objects.contains(where: { $0.name == name + Self.goneSuffix }) { try await backend.delete(name + Self.goneSuffix) }
            report.uploaded += 1
            written.append(name + Self.clipSuffix)
        }
        return written
    }

    /// Removes the whole synced copy, for starting over after a lost passphrase. Clips on this device stay.
    public static func erase(_ backend: any SyncBackend) async throws {
        for object in try await backend.list() { try await backend.delete(object.name) }
    }
}
