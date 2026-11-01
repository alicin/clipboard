import AppKit
import ClipboardCore
import Observation
import Security

protocol SyncSecrets {
    func value(for name: String) -> String?
    func set(_ value: String?, for name: String)
}

struct KeychainSyncSecrets: SyncSecrets {
    private static let service = "com.bunniesinc.clipboard.sync"

    private func query(_ name: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: name]
    }

    func value(for name: String) -> String? {
        var search = query(name)
        search[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for name: String) {
        SecItemDelete(query(name) as CFDictionary)
        guard let value else { return }
        var item = query(name)
        item[kSecValueData] = Data(value.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// UI tests can't be allowed to raise keychain prompts.
final class MemorySyncSecrets: SyncSecrets {
    private var values: [String: String] = [:]
    func value(for name: String) -> String? { values[name] }
    func set(_ value: String?, for name: String) { values[name] = value }
}

@MainActor @Observable
final class SyncController {
    enum Status: Equatable {
        case off
        case needsGoogleApp
        case needsPassphrase
        case upToDate
        case syncing
        case failed(String)
    }

    private enum Secret {
        static let clientID = "google-client-id"
        static let clientSecret = "google-client-secret"
        static let refreshToken = "google-refresh-token"
        static let account = "google-account"
        static func key(for mode: SyncMode) -> String { "key-\(mode.rawValue)" }
    }

    private(set) var status: Status = .off
    private(set) var lastSynced: Date?
    private(set) var googleAccount: String?
    private(set) var isGoogleConnected = false
    private(set) var isConnectingGoogle = false
    private(set) var googleProblem: String?
    private(set) var isUnlocking = false
    private(set) var passphraseProblem: String?
    private(set) var clipsSent = 0

    @ObservationIgnored private let store: ClipStore
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let secrets: any SyncSecrets
    @ObservationIgnored private let onArrival: (CaptureResult) -> Void
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var drive: GoogleDriveBackend?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var connectTask: Task<Void, Never>?

    private static let everySeconds: TimeInterval = 120
    private static let afterChangeSeconds: TimeInterval = 4
    private static let lastBackendKey = "lastSyncBackend"

    static var iCloudFolder: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["CLIPBOARD_TEST_SYNC_FOLDER"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Clipboard Sync", isDirectory: true)
    }

    var clientID: String { secrets.value(for: Secret.clientID) ?? "" }
    var clientSecret: String { secrets.value(for: Secret.clientSecret) ?? "" }

    init(store: ClipStore, preferences: Preferences, onArrival: @escaping (CaptureResult) -> Void) {
        self.store = store
        self.preferences = preferences
        self.onArrival = onArrival
        secrets = AppEnvironment.isUITest ? MemorySyncSecrets() : KeychainSyncSecrets()
    }

    func start() {
        preferences.onSyncModeChanged = { [weak self] in self?.modeChanged() }
        observer = NotificationCenter.default.addObserver(forName: .clipsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon() }
        }
        let timer = Timer(timeInterval: Self.everySeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        configure()
        syncNow()
    }

    private func modeChanged() {
        let mode = preferences.syncMode
        // Turning sync off and back on isn't a move. Everything recorded still holds for the same place.
        if mode != .off, AppEnvironment.defaults.string(forKey: Self.lastBackendKey) != mode.rawValue {
            try? store.resetSyncState()
            AppEnvironment.defaults.set(mode.rawValue, forKey: Self.lastBackendKey)
        }
        configure()
        syncNow()
    }

    private func configure() {
        let mode = preferences.syncMode
        engine = nil
        drive = nil
        googleProblem = nil
        passphraseProblem = nil
        isGoogleConnected = secrets.value(for: Secret.refreshToken) != nil
        googleAccount = secrets.value(for: Secret.account)
        guard mode != .off else {
            status = .off
            return
        }
        guard let backend = makeBackend(for: mode) else {
            status = .needsGoogleApp
            return
        }
        guard let stored = secrets.value(for: Secret.key(for: mode)), let master = Data(base64Encoded: stored) else {
            status = .needsPassphrase
            return
        }
        engine = SyncEngine(store: store, backend: backend, keys: SyncKeys(master: master))
        status = .upToDate
    }

    private func makeBackend(for mode: SyncMode) -> (any SyncBackend)? {
        switch mode {
        case .off:
            return nil
        case .iCloud:
            return FolderSyncBackend(directory: Self.iCloudFolder)
        case .googleDrive:
            if let drive { return drive }
            guard let refresh = secrets.value(for: Secret.refreshToken), !clientID.isEmpty else { return nil }
            let backend = GoogleDriveBackend(client: GoogleClient(id: clientID, secret: clientSecret), refreshToken: refresh)
            drive = backend
            return backend
        }
    }

    private var retentionCutoff: Date? {
        preferences.retentionDays > 0 ? Date().addingTimeInterval(-Double(preferences.retentionDays) * 86400) : nil
    }

    func syncSoon(after delay: TimeInterval = afterChangeSeconds) {
        guard engine != nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func syncNow() {
        guard let engine, !isRunning else { return }
        isRunning = true
        status = .syncing
        let cutoff = retentionCutoff
        Task {
            do {
                let report = try await engine.run(keepingOnlyAfter: cutoff)
                lastSynced = Date()
                clipsSent += report.uploaded
                status = .upToDate
                report.arrived.forEach(onArrival)
                if report.downloaded > 0 || report.deleted > 0 {
                    NotificationCenter.default.post(name: .clipsChanged, object: nil)
                }
                if report.hasMoreWork { syncSoon(after: 0.5) }
            } catch SyncError.wrongPassphrase {
                forgetKey()
                passphraseProblem = "This folder has a different passphrase now, probably because another device started over. Enter it to keep syncing."
            } catch SyncError.needsReconnect {
                secrets.set(nil, for: Secret.refreshToken)
                configure()
                googleProblem = SyncError.needsReconnect.description
            } catch let error as SyncError {
                status = .failed(error.description)
            } catch let error as URLError {
                status = .failed("Couldn't reach Google Drive (\(error.localizedDescription)). Clipboard will try again.")
            } catch {
                status = .failed(preferences.syncMode == .iCloud
                    ? "Couldn't use the iCloud Drive folder. Check that iCloud Drive is on and that Clipboard is allowed to use it."
                    : error.localizedDescription)
            }
            isRunning = false
        }
    }

    func unlock(passphrase: String) {
        let mode = preferences.syncMode
        guard let backend = makeBackend(for: mode), !passphrase.isEmpty else { return }
        isUnlocking = true
        passphraseProblem = nil
        Task {
            do {
                let keys = try await SyncKeys.join(backend, passphrase: passphrase)
                secrets.set(keys.master.base64EncodedString(), for: Secret.key(for: mode))
                configure()
                syncNow()
            } catch let error as SyncError {
                passphraseProblem = error.description
            } catch {
                passphraseProblem = mode == .iCloud
                    ? "Couldn't use the iCloud Drive folder. Check that iCloud Drive is on and that Clipboard is allowed to use it."
                    : "Couldn't reach Google Drive. Check your connection and try again."
            }
            isUnlocking = false
        }
    }

    private func forgetKey() {
        secrets.set(nil, for: Secret.key(for: preferences.syncMode))
        configure()
    }

    func connectGoogle(clientID: String, clientSecret: String) {
        let client = GoogleClient(
            id: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !client.id.isEmpty, !client.secret.isEmpty else { return }
        secrets.set(client.id, for: Secret.clientID)
        secrets.set(client.secret, for: Secret.clientSecret)
        isConnectingGoogle = true
        googleProblem = nil
        connectTask = Task {
            do {
                let refresh = try await GoogleSignIn.run(client: client) { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                let backend = GoogleDriveBackend(client: client, refreshToken: refresh)
                let account = try? await backend.accountEmail()
                secrets.set(refresh, for: Secret.refreshToken)
                secrets.set(account, for: Secret.account)
                configure()
                syncNow()
            } catch is CancellationError {
                // The user changed their mind.
            } catch {
                googleProblem = (error as? SyncError)?.description ?? "Google sign-in didn't finish: \(error.localizedDescription)"
            }
            isConnectingGoogle = false
        }
    }

    func cancelGoogleConnection() {
        connectTask?.cancel()
    }

    func disconnectGoogle() {
        secrets.set(nil, for: Secret.refreshToken)
        secrets.set(nil, for: Secret.account)
        secrets.set(nil, for: Secret.key(for: .googleDrive))
        configure()
    }

    /// For a lost passphrase. Every device has to enter the new one afterwards.
    func startOver() {
        let mode = preferences.syncMode
        guard let backend = makeBackend(for: mode) else { return }
        Task {
            do {
                try await SyncEngine.erase(backend)
                try? store.resetSyncState()
                forgetKey()
            } catch {
                status = .failed("Couldn't erase the synced copy: \(error.localizedDescription)")
            }
        }
    }
}
