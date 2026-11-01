import CryptoKit
import Foundation
import Testing

@testable import ClipboardCore

/// Two devices sharing one folder.
private final class SyncPair {
    let folder: URL
    let backend: FolderSyncBackend
    let macA: TemporaryStore
    let macB: TemporaryStore
    let engineA: SyncEngine
    let engineB: SyncEngine

    init(batch: Int = 100) async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-tests-\(UUID().uuidString)")
        backend = FolderSyncBackend(directory: folder)
        macA = try TemporaryStore()
        macB = try TemporaryStore()
        let keysA = try await SyncKeys.join(backend, passphrase: "correct horse", iterations: 1000)
        let keysB = try await SyncKeys.join(backend, passphrase: "correct horse", iterations: 1000)
        engineA = SyncEngine(store: macA.store, backend: backend, keys: keysA, batch: batch)
        engineB = SyncEngine(store: macB.store, backend: backend, keys: keysB, batch: batch)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func settle() async throws {
        _ = try await engineA.run()
        _ = try await engineB.run()
        _ = try await engineA.run()
    }

    func objectData() throws -> [Data] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).map { try Data(contentsOf: $0) }
    }
}

@Suite struct SyncEngineTests {
    private let secret = "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"

    @Test func aClipCopiedOnOneMacArrivesOnTheOther() async throws {
        let pair = try await SyncPair()
        let original = try pair.macA.add("Buy oat milk", name: "Notes")
        let first = try await pair.engineA.run()
        #expect(first.uploaded == 1)

        let second = try await pair.engineB.run()
        #expect(second.downloaded == 1)
        #expect(second.arrived.first?.isNew == true)
        let arrived = try #require(try pair.macB.store.clips(ClipQuery()).first)
        #expect(arrived.preview == "Buy oat milk")
        #expect(arrived.source.name == "Notes")
        #expect(abs(arrived.createdAt.timeIntervalSince(original.createdAt)) < 0.01)
        #expect(try pair.macB.store.fullText(clipID: arrived.id) == "Buy oat milk")
    }

    @Test func imagesArriveWholeWithAThumbnail() async throws {
        let pair = try await SyncPair()
        let picture = samplePNG()
        let draft = try #require(draft(from: [[Representation(uti: "public.png", data: picture)]]))
        try pair.macA.store.capture(draft)
        try await pair.settle()
        let arrived = try #require(try pair.macB.store.clips(ClipQuery()).first)
        #expect(arrived.kind == .image)
        #expect(arrived.hasThumbnail)
        #expect(try pair.macB.store.payload(for: arrived)[0][0].data == picture)
    }

    @Test func aSecondPassHasNothingToDo() async throws {
        let pair = try await SyncPair()
        try pair.macA.add("Buy oat milk")
        try await pair.settle()
        let again = try await pair.engineA.run()
        let other = try await pair.engineB.run()
        #expect(again.uploaded == 0 && again.downloaded == 0)
        #expect(other.uploaded == 0 && other.downloaded == 0)
    }

    @Test func nothingReadableReachesTheCloud() async throws {
        let pair = try await SyncPair()
        try pair.macA.add("The launch code is banana")
        let clip = try pair.macA.store.clips(ClipQuery()).first
        _ = try await pair.engineA.run()
        let names = try FileManager.default.contentsOfDirectory(atPath: pair.folder.path)
        let hash = try #require(clip).uuid
        #expect(!names.contains { $0.contains(hash) })
        for data in try pair.objectData() {
            #expect(data.range(of: Data("banana".utf8)) == nil)
            #expect(data.range(of: Data("Example".utf8)) == nil)
        }
    }

    @Test func objectNamesDontGiveAwayTheContentHash() async throws {
        let pair = try await SyncPair()
        try pair.macA.add("Buy oat milk")
        _ = try await pair.engineA.run()
        let identity = SHA256.hash(data: Data("text:Buy oat milk".utf8)).map { String(format: "%02x", $0) }.joined()
        let names = try FileManager.default.contentsOfDirectory(atPath: pair.folder.path)
        #expect(names.contains { $0.hasSuffix(".clip") })
        #expect(!names.contains { $0.contains(identity) })
    }

    @Test func filesSecretsAndHugeClipsStayOnThisMac() async throws {
        let pair = try await SyncPair()
        try pair.macA.add(secret, secrets: .hide)
        let file = [[utf8Rep("file:///Users/me/kitten.png", type: "public.file-url")]]
        try pair.macA.store.capture(try #require(draft(from: file)))
        let huge = try #require(draft(from: [[Representation(uti: "com.example.big", data: Data(count: 26_000_000))]]))
        try pair.macA.store.capture(huge)
        let report = try await pair.engineA.run()
        #expect(report.uploaded == 0)
        #expect(try pair.objectData().count == 1)
    }

    @Test func aDeletionReachesTheOtherMac() async throws {
        let pair = try await SyncPair()
        let clip = try pair.macA.add("Buy oat milk")
        try await pair.settle()
        #expect(try pair.macB.store.clips(ClipQuery()).count == 1)

        try pair.macA.store.delete(clipID: clip.id)
        _ = try await pair.engineA.run()
        let report = try await pair.engineB.run()
        #expect(report.deleted == 1)
        #expect(try pair.macB.store.clips(ClipQuery()).isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: pair.folder.path)
        #expect(names.contains { $0.hasSuffix(".gone") })
        #expect(!names.contains { $0.hasSuffix(".clip") })
    }

    @Test func aDeletedClipDoesntComeBackOnTheMacThatDeletedIt() async throws {
        let pair = try await SyncPair()
        let clip = try pair.macA.add("Buy oat milk")
        try await pair.settle()
        try pair.macA.store.delete(clipID: clip.id)
        try await pair.settle()
        try await pair.settle()
        #expect(try pair.macA.store.clips(ClipQuery()).isEmpty)
        #expect(try pair.macB.store.clips(ClipQuery()).isEmpty)
    }

    @Test func copyingADeletedClipAgainBringsItBackEverywhere() async throws {
        let pair = try await SyncPair()
        let clip = try pair.macA.add("Buy oat milk", at: Date().addingTimeInterval(-100))
        try await pair.settle()
        try pair.macB.store.delete(clipID: try #require(try pair.macB.store.clips(ClipQuery()).first).id)
        try await pair.settle()
        #expect(try pair.macA.store.clip(id: clip.id) == nil)

        try pair.macA.add("Buy oat milk", at: Date().addingTimeInterval(5))
        try await pair.settle()
        #expect(try pair.macB.store.clips(ClipQuery()).count == 1)
        #expect(try pair.macA.store.clips(ClipQuery()).count == 1)
    }

    @Test func clearingHistoryClearsEveryDevice() async throws {
        let pair = try await SyncPair()
        let keep = try pair.macA.add("Pinned one")
        try pair.macA.add("Loose one")
        let board = try pair.macA.store.createPinboard(name: "Work", color: "sky")
        try pair.macA.store.pin(clipID: keep.id, pinboardID: board.id)
        try await pair.settle()
        #expect(try pair.macB.store.clips(ClipQuery()).count == 2)

        try pair.macA.store.clearHistory(keepPinned: true)
        try await pair.settle()
        #expect(try pair.macB.store.clips(ClipQuery()).map(\.preview) == ["Pinned one"])
        #expect(try pair.macA.store.clips(ClipQuery()).map(\.preview) == ["Pinned one"])
    }

    @Test func aRenameAndPinsTravelAndTheNewestChangeWins() async throws {
        let pair = try await SyncPair()
        let clip = try pair.macA.add("Buy oat milk")
        try await pair.settle()
        let copy = try #require(try pair.macB.store.clips(ClipQuery()).first)

        try pair.macB.store.rename(clipID: copy.id, title: "Groceries")
        let board = try pair.macB.store.createPinboard(name: "Home", color: "mint")
        try pair.macB.store.pin(clipID: copy.id, pinboardID: board.id)
        try await pair.settle()
        let renamed = try #require(try pair.macA.store.clip(id: clip.id))
        #expect(renamed.title == "Groceries")
        let boardsOnA = try pair.macA.store.pinboards()
        #expect(boardsOnA.map(\.name) == ["Home"])
        #expect(renamed.pinboardIDs == boardsOnA.map(\.id))

        try pair.macA.store.rename(clipID: clip.id, title: "Shopping")
        try await Task.sleep(for: .milliseconds(20))
        try pair.macB.store.rename(clipID: copy.id, title: "Errands")
        try await pair.settle()
        #expect(try pair.macA.store.clip(id: clip.id)?.title == "Errands")
        #expect(try pair.macB.store.clip(id: copy.id)?.title == "Errands")
    }

    @Test func retentionKeepsOldClipsOutButLetsPinnedOnesThrough() async throws {
        let pair = try await SyncPair()
        let old = Date().addingTimeInterval(-40 * 86400)
        try pair.macA.add("Old and loose", at: old)
        let pinned = try pair.macA.add("Old and pinned", at: old)
        let board = try pair.macA.store.createPinboard(name: "Keep", color: "sky")
        try pair.macA.store.pin(clipID: pinned.id, pinboardID: board.id)
        _ = try await pair.engineA.run()
        _ = try await pair.engineB.run(keepingOnlyAfter: Date().addingTimeInterval(-7 * 86400))
        #expect(try pair.macB.store.clips(ClipQuery()).map(\.preview) == ["Old and pinned"])
    }

    @Test func aPrunedClipStaysPruned() async throws {
        let pair = try await SyncPair()
        try pair.macA.add("Old one", at: Date().addingTimeInterval(-40 * 86400))
        try await pair.settle()
        #expect(try pair.macB.store.prune(before: Date().addingTimeInterval(-7 * 86400)) == 1)
        try await pair.settle()
        #expect(try pair.macB.store.clips(ClipQuery()).isEmpty)
        #expect(try pair.macA.store.clips(ClipQuery()).count == 1)
    }

    @Test func largeBacklogsGoInBatches() async throws {
        let pair = try await SyncPair(batch: 2)
        for number in 1...5 { try pair.macA.add("Clip \(number)") }
        let first = try await pair.engineA.run()
        #expect(first.uploaded == 2)
        #expect(first.hasMoreWork)
        _ = try await pair.engineA.run()
        let last = try await pair.engineA.run()
        #expect(last.uploaded == 1)
        #expect(!last.hasMoreWork)
        for _ in 1...3 { _ = try await pair.engineB.run() }
        #expect(try pair.macB.store.clips(ClipQuery()).count == 5)
    }

    @Test func anEarlierFormatRecordOnADeviceIsStillUnderstoodAndAFutureOneIsLeftAlone() async throws {
        let pair = try await SyncPair()
        let keys = try await SyncKeys.join(pair.backend, passphrase: "correct horse")
        let future = try keys.seal(Data(#"{"format":2,"hash":"x","updatedAt":1}"#.utf8))
        _ = try await pair.backend.write("abc.clip", data: future)
        let first = try await pair.engineB.run()
        #expect(first.downloaded == 0)
        #expect(try pair.macB.store.clips(ClipQuery()).isEmpty)
        #expect(try Data(contentsOf: pair.folder.appendingPathComponent("abc.clip")) == future)
    }

    @Test func aWrongPassphraseIsRefusedWhenJoining() async throws {
        let pair = try await SyncPair()
        await #expect(throws: SyncError.wrongPassphrase) {
            _ = try await SyncKeys.join(pair.backend, passphrase: "wrong horse", iterations: 1000)
        }
    }

    @Test func anEngineStopsIfSomeoneStartedOverWithANewPassphrase() async throws {
        let pair = try await SyncPair()
        try pair.macA.add("Buy oat milk")
        try await SyncEngine.erase(pair.backend)
        _ = try await SyncKeys.join(pair.backend, passphrase: "a new one", iterations: 1000)
        await #expect(throws: SyncError.wrongPassphrase) { _ = try await pair.engineA.run() }
        #expect(try pair.objectData().count == 1)
    }

    @Test func erasingLeavesLocalClipsAlone() async throws {
        let pair = try await SyncPair()
        try pair.macA.add("Buy oat milk")
        try await pair.settle()
        try await SyncEngine.erase(pair.backend)
        #expect(try pair.objectData().isEmpty)
        #expect(try pair.macA.store.clips(ClipQuery()).count == 1)
        await #expect(throws: SyncError.wrongPassphrase) { _ = try await pair.engineA.run() }
    }

    @Test func switchingWhereClipsSyncSendsEverythingAgain() async throws {
        let pair = try await SyncPair()
        try pair.macA.add("Buy oat milk")
        _ = try await pair.engineA.run()
        try pair.macA.store.resetSyncState()
        let otherFolder = FolderSyncBackend(directory: pair.folder.appendingPathComponent("elsewhere"))
        let keys = try await SyncKeys.join(otherFolder, passphrase: "another", iterations: 1000)
        let report = try await SyncEngine(store: pair.macA.store, backend: otherFolder, keys: keys).run()
        #expect(report.uploaded == 1)
    }

    @Test func goneFilesExpire() async throws {
        let pair = try await SyncPair()
        let clip = try pair.macA.add("Buy oat milk")
        _ = try await pair.engineA.run()
        try pair.macA.store.delete(clipID: clip.id)
        _ = try await pair.engineA.run()
        _ = try await pair.engineA.run(now: Date().addingTimeInterval(31 * 86400))
        let names = try FileManager.default.contentsOfDirectory(atPath: pair.folder.path)
        #expect(names == ["sync-info.json"])
    }
}

/// Google Drive's REST API and token endpoint, as far as Clipboard uses them.
private final class FakeDriveProtocol: URLProtocol {
    struct File {
        var id: String
        var name: String
        var data: Data
        var modified: Date
    }

    nonisolated(unsafe) static var files: [File] = []
    nonisolated(unsafe) static var pendingUploads: [String: (id: String?, name: String)] = [:]
    nonisolated(unsafe) static var requests: [String] = []
    nonisolated(unsafe) static var validToken = "token-1"
    nonisolated(unsafe) static var tokensIssued = 0
    nonisolated(unsafe) static var pageSize = 1000
    nonisolated(unsafe) static var failure: (status: Int, body: String)?
    nonisolated(unsafe) static var refreshError: String?
    nonisolated(unsafe) static var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private static let lock = NSRecursiveLock()

    static func reset() {
        files = []
        pendingUploads = [:]
        requests = []
        validToken = "token-1"
        tokensIssued = 0
        pageSize = 1000
        failure = nil
        refreshError = nil
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeDriveProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private var body: Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func respond(_ status: Int, _ data: Data = Data(), headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func json(_ object: Any, status: Int = 200) {
        respond(status, try! JSONSerialization.data(withJSONObject: object))
    }

    private static func metadata(_ file: File) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "id": file.id, "name": file.name, "modifiedTime": formatter.string(from: file.modified),
            "md5Checksum": Insecure.MD5.hash(data: file.data).map { String(format: "%02x", $0) }.joined(),
        ]
    }

    override func startLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let url = request.url, let method = request.httpMethod else { return }
        Self.requests.append("\(method) \(url.path)")

        if url.host == "oauth2.googleapis.com" {
            let form = String(decoding: body, as: UTF8.self)
            if let error = Self.refreshError, form.contains("grant_type=refresh_token") { return json(["error": error], status: 400) }
            Self.tokensIssued += 1
            Self.validToken = "token-\(Self.tokensIssued)"
            var answer: [String: Any] = ["access_token": Self.validToken, "expires_in": 3600]
            if form.contains("grant_type=authorization_code") { answer["refresh_token"] = "refresh-from-\(form.contains("code=the-code") ? "code" : "other")" }
            return json(answer)
        }
        if request.value(forHTTPHeaderField: "Authorization") != "Bearer \(Self.validToken)", !url.path.contains("/upload/session/") {
            return json(["error": ["code": 401, "message": "Invalid Credentials"]], status: 401)
        }
        if let failure = Self.failure {
            Self.failure = nil
            return respond(failure.status, Data(failure.body.utf8))
        }

        let parts = url.path.split(separator: "/").map(String.init)
        switch (method, parts.first) {
        case ("GET", "drive") where parts.last == "about":
            json(["user": ["emailAddress": "me@example.com"]])
        case ("GET", "drive") where parts.last == "files":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.first { $0.name == "spaces" }?.value == "appDataFolder")
            let start = query.first { $0.name == "pageToken" }?.value.flatMap(Int.init) ?? 0
            let page = Array(Self.files.dropFirst(start).prefix(Self.pageSize))
            var answer: [String: Any] = ["files": page.map(Self.metadata)]
            if start + page.count < Self.files.count { answer["nextPageToken"] = String(start + page.count) }
            json(answer)
        case ("GET", "drive"):
            guard let file = Self.files.first(where: { $0.id == parts.last }) else { return respond(404) }
            respond(200, file.data)
        case ("DELETE", "drive"):
            guard let index = Self.files.firstIndex(where: { $0.id == parts.last }) else { return respond(404) }
            Self.files.remove(at: index)
            respond(204)
        case ("POST", "upload"):
            let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            #expect((fields?["parents"] as? [String]) == ["appDataFolder"])
            let session = UUID().uuidString
            Self.pendingUploads[session] = (nil, fields?["name"] as? String ?? "")
            respond(200, headers: ["Location": "https://www.googleapis.com/upload/session/\(session)"])
        case ("PATCH", "upload"):
            guard let existing = Self.files.first(where: { $0.id == parts.last }) else { return respond(404) }
            let session = UUID().uuidString
            Self.pendingUploads[session] = (existing.id, existing.name)
            respond(200, headers: ["Location": "https://www.googleapis.com/upload/session/\(session)"])
        case ("PUT", "upload"):
            guard let session = parts.last, let pending = Self.pendingUploads.removeValue(forKey: session) else { return respond(404) }
            Self.clock = Self.clock.addingTimeInterval(1)
            let data = body
            if let id = pending.id, let index = Self.files.firstIndex(where: { $0.id == id }) {
                Self.files[index].data = data
                Self.files[index].modified = Self.clock
                json(Self.metadata(Self.files[index]))
            } else {
                let file = File(id: UUID().uuidString, name: pending.name, data: data, modified: Self.clock)
                Self.files.append(file)
                json(Self.metadata(file))
            }
        default:
            respond(400)
        }
    }
}

@Suite(.serialized) struct GoogleDriveTests {
    private let client = GoogleClient(id: "client-id.apps.googleusercontent.com", secret: "client-secret")

    private func backend(refreshToken: String = "refresh") -> GoogleDriveBackend {
        GoogleDriveBackend(client: client, refreshToken: refreshToken, session: FakeDriveProtocol.session)
    }

    init() { FakeDriveProtocol.reset() }

    @Test func writesReadsListsAndDeletes() async throws {
        let drive = backend()
        let first = try await drive.write("one.clip", data: Data("first".utf8))
        let second = try await drive.write("one.clip", data: Data("second".utf8))
        #expect(first != second)
        #expect(FakeDriveProtocol.files.count == 1)

        let listed = try await backend().list()
        #expect(listed.map(\.name) == ["one.clip"])
        #expect(listed.first?.version == second)
        #expect(listed.first?.modified.timeIntervalSince1970 ?? 0 > 1_000_000_000)

        let reader = backend()
        _ = try await reader.list()
        #expect(try await reader.read("one.clip") == Data("second".utf8))
        try await reader.delete("one.clip")
        #expect(FakeDriveProtocol.files.isEmpty)
    }

    @Test func readsEveryPageOfALongList() async throws {
        let drive = backend()
        for number in 1...5 { _ = try await drive.write("\(number).clip", data: Data([UInt8(number)])) }
        FakeDriveProtocol.pageSize = 2
        #expect(try await backend().list().count == 5)
    }

    @Test func twoDevicesUploadingTheSameNameEndUpWithOneFile() async throws {
        _ = try await backend().write("same.clip", data: Data("older".utf8))
        _ = try await backend().write("same.clip", data: Data("newer".utf8))
        #expect(FakeDriveProtocol.files.count == 2)
        let drive = backend()
        let listed = try await drive.list()
        #expect(listed.count == 1)
        #expect(FakeDriveProtocol.files.count == 1)
        #expect(try await drive.read("same.clip") == Data("newer".utf8))
    }

    @Test func refreshesAnExpiredTokenAndRetries() async throws {
        let drive = backend()
        _ = try await drive.list()
        let issued = FakeDriveProtocol.tokensIssued
        FakeDriveProtocol.validToken = "expired-elsewhere"
        #expect(try await drive.list().isEmpty)
        #expect(FakeDriveProtocol.tokensIssued == issued + 1)
    }

    @Test func aRevokedSignInAsksToReconnect() async throws {
        FakeDriveProtocol.refreshError = "invalid_grant"
        await #expect(throws: SyncError.needsReconnect) { _ = try await backend().list() }
    }

    @Test func aBadClientSaysSo() async throws {
        FakeDriveProtocol.refreshError = "invalid_client"
        do {
            _ = try await backend().list()
            Issue.record("expected a failure")
        } catch let error as SyncError {
            #expect(error.description.contains("client ID and secret"))
        }
    }

    @Test func explainsTheDriveAPIBeingOff() async throws {
        let drive = backend()
        _ = try await drive.list()
        FakeDriveProtocol.failure = (403, #"{"error":{"code":403,"message":"long text","errors":[{"reason":"accessNotConfigured"}]}}"#)
        do {
            _ = try await drive.list()
            Issue.record("expected a failure")
        } catch let error as SyncError {
            #expect(error.description.contains("isn't turned on"))
        }
    }

    @Test func readsTheAccountEmail() async throws {
        #expect(try await backend().accountEmail() == "me@example.com")
    }

    @Test func twoDevicesSyncThroughDrive() async throws {
        let macA = try TemporaryStore()
        let macB = try TemporaryStore()
        let driveA = backend()
        let driveB = backend()
        let keysA = try await SyncKeys.join(driveA, passphrase: "correct horse", iterations: 1000)
        let keysB = try await SyncKeys.join(driveB, passphrase: "correct horse", iterations: 1000)
        let engineA = SyncEngine(store: macA.store, backend: driveA, keys: keysA)
        let engineB = SyncEngine(store: macB.store, backend: driveB, keys: keysB)

        let clip = try macA.add("Buy oat milk")
        #expect(try await engineA.run().uploaded == 1)
        #expect(try await engineB.run().downloaded == 1)
        #expect(try macB.store.clips(ClipQuery()).first?.preview == "Buy oat milk")
        #expect(!FakeDriveProtocol.files.contains { $0.data.range(of: Data("oat milk".utf8)) != nil })

        let copy = try #require(try macB.store.clips(ClipQuery()).first)
        try macB.store.rename(clipID: copy.id, title: "Groceries")
        _ = try await engineB.run()
        _ = try await engineA.run()
        #expect(try macA.store.clip(id: clip.id)?.title == "Groceries")

        try macA.store.delete(clipID: clip.id)
        _ = try await engineA.run()
        #expect(try await engineB.run().deleted == 1)
        #expect(try macB.store.clips(ClipQuery()).isEmpty)
    }

    @Test func theSignInPageAsksForOnlyTheHiddenFolderAndUsesPKCE() throws {
        let url = GoogleSignIn.authorizationURL(client: client, redirect: "http://127.0.0.1:5000", state: "s", challenge: "c")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.google.com")
        #expect(items["scope"] == "https://www.googleapis.com/auth/drive.appdata")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["access_type"] == "offline")
        #expect(items["prompt"] == "consent")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5000")
    }

    @Test func signsInThroughTheLoopback() async throws {
        let refresh = try await GoogleSignIn.run(client: client, session: FakeDriveProtocol.session) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = items.first { $0.name == "redirect_uri" }!.value!
            let state = items.first { $0.name == "state" }!.value!
            Task {
                _ = try? await URLSession.shared.data(from: URL(string: "\(redirect)/favicon.ico")!)
                _ = try? await URLSession.shared.data(from: URL(string: "\(redirect)/?state=\(state)&code=the-code")!)
            }
        }
        #expect(refresh == "refresh-from-code")
    }

    @Test func refusingOnGooglesPageSaysSo() async throws {
        do {
            _ = try await GoogleSignIn.run(client: client, session: FakeDriveProtocol.session) { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                let redirect = items.first { $0.name == "redirect_uri" }!.value!
                let state = items.first { $0.name == "state" }!.value!
                Task { _ = try? await URLSession.shared.data(from: URL(string: "\(redirect)/?state=\(state)&error=access_denied")!) }
            }
            Issue.record("expected a failure")
        } catch let error as SyncError {
            #expect(error.description.contains("wasn't allowed"))
        }
    }

    @Test func aMismatchedStateIsRefused() async throws {
        await #expect(throws: SyncError.self) {
            _ = try await GoogleSignIn.run(client: client, session: FakeDriveProtocol.session) { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                let redirect = items.first { $0.name == "redirect_uri" }!.value!
                Task { _ = try? await URLSession.shared.data(from: URL(string: "\(redirect)/?state=forged&code=the-code")!) }
            }
        }
    }
}
