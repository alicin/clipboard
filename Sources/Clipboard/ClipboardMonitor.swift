import AppKit
import ClipboardCore

extension Notification.Name {
    static let clipsChanged = Notification.Name("com.bunniesinc.clipboard.clipsChanged")
}

enum AppPasteboard {
    static let shared: NSPasteboard = {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["CLIPBOARD_TEST_PASTEBOARD"] {
            return NSPasteboard(name: NSPasteboard.Name(name))
        }
        #endif
        return .general
    }()
}

@MainActor
final class PasteboardWriter {
    private let store: ClipStore
    private let pasteboard = AppPasteboard.shared
    private(set) var lastWrittenChange = -1

    init(store: ClipStore) {
        self.store = store
    }

    @discardableResult
    func write(_ clip: Clip, plainText: Bool) -> Bool {
        var items: [NSPasteboardItem] = []
        if plainText, let text = try? store.fullText(clipID: clip.id) {
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            items = [item]
        } else {
            guard let payload = try? store.payload(for: clip), !payload.isEmpty else { return false }
            items = payload.map { reps in
                let item = NSPasteboardItem()
                for rep in reps {
                    item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.uti))
                }
                return item
            }
        }
        items[0].setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardMarkers.restored))
        pasteboard.clearContents()
        let succeeded = pasteboard.writeObjects(items)
        lastWrittenChange = pasteboard.changeCount
        return succeeded
    }
}

@MainActor
final class ClipboardMonitor {
    private let store: ClipStore
    private let writer: PasteboardWriter
    private let preferences: Preferences
    private let pasteboard = AppPasteboard.shared
    private let queue = DispatchQueue(label: "com.bunniesinc.clipboard.capture", qos: .userInitiated)
    private var lastChange: Int
    private var timer: Timer?

    var onCapture: ((CaptureResult) -> Void)?

    init(store: ClipStore, writer: PasteboardWriter, preferences: Preferences) {
        self.store = store
        self.writer = writer
        self.preferences = preferences
        lastChange = pasteboard.changeCount
    }

    func start() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let change = pasteboard.changeCount
        guard change != lastChange else { return }
        lastChange = change
        guard change != writer.lastWrittenChange, !preferences.isPaused else { return }

        let front = NSWorkspace.shared.frontmostApplication
        let source = ClipSource(bundleID: front?.bundleIdentifier, name: front?.localizedName)
        let ignored = Set(preferences.ignoredBundleIDs)
        if let bundleID = source.bundleID, ignored.contains(bundleID) { return }
        let skipSecrets = preferences.skipSecrets
        let store = store

        // Reads go off the main thread: they can force the source app to render lazily provided
        // data, and on recent macOS versions can block on the system's pasteboard privacy alert.
        queue.async { [weak self] in
            guard let capture = Self.read(expectedChange: change, frontmost: source) else { return }
            if let bundleID = capture.source.bundleID, ignored.contains(bundleID) { return }
            let built = ClipBuilder.build(items: capture.items, source: capture.source, skipSecrets: skipSecrets)
            guard case .clip(let draft) = built, let result = try? store.capture(draft) else { return }
            DispatchQueue.main.async {
                self?.onCapture?(result)
                NotificationCenter.default.post(name: .clipsChanged, object: nil)
            }
        }
    }

    private struct RawCapture {
        let items: [[Representation]]
        let source: ClipSource
    }

    private nonisolated static func read(expectedChange: Int, frontmost: ClipSource) -> RawCapture? {
        let pasteboard = AppPasteboard.shared
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        let types = Set(items.flatMap { $0.types.map(\.rawValue) })
        guard !PasteboardMarkers.shouldIgnore(types: types) else { return nil }

        let raw = items.map { item in
            item.types.compactMap { type -> Representation? in
                guard let data = item.data(forType: type) else { return nil }
                return Representation(uti: type.rawValue, data: data)
            }
        }
        // A copy that landed mid-read makes this snapshot a mix of two clips; the next tick picks it up.
        guard pasteboard.changeCount == expectedChange else { return nil }

        var source = frontmost
        if types.contains(PasteboardMarkers.remote) {
            source = ClipSource(bundleID: nil, name: "Universal Clipboard")
        } else if let rep = raw.joined().first(where: { $0.uti == PasteboardMarkers.source }),
            let bundleID = String(data: rep.data, encoding: .utf8), !bundleID.isEmpty {
            var name: String?
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            }
            source = ClipSource(bundleID: bundleID, name: name ?? frontmost.name)
        }
        return RawCapture(items: raw, source: source)
    }
}
