import AppKit
import Observation

/// Debug builds started by scripts/ui_test.py keep away from the user's real clipboard, preferences and hotkeys.
enum AppEnvironment {
    static let isUITest: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CLIPBOARD_TEST_PASTEBOARD"] != nil
        #else
        return false
        #endif
    }()

    /// Rendering the demo video from Sources/Clipboard/Demo instead of running as an app.
    static let isDemo: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CLIPBOARD_DEMO_OUTPUT"] != nil
        #else
        return false
        #endif
    }()

    /// A key window would swallow whatever the user is typing, so tests run off-screen and never take focus.
    /// CLIPBOARD_TEST_VISIBLE opts out, for the few checks of real focus behaviour.
    static let isHeadless = isUITest && ProcessInfo.processInfo.environment["CLIPBOARD_TEST_VISIBLE"] == nil

    /// Keeps a test window drawing without showing it: only its transparent bottom margin stays on screen,
    /// just under the menu bar, and the rest extends above the top of the screen, where no display reaches.
    static func placed(_ frame: NSRect) -> NSRect {
        guard isHeadless, let main = NSScreen.screens.first else { return frame }
        return NSRect(origin: NSPoint(x: main.visibleFrame.minX + 40, y: main.visibleFrame.maxY - 8), size: frame.size)
    }

    static let defaults: UserDefaults =
        isUITest ? UserDefaults(suiteName: "com.bunniesinc.clipboard.uitest") ?? .standard : .standard
}

@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    static let defaultIgnoredApps = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc",
        "in.sinew.Enpass-Desktop",
        "com.nordsec.nordpass",
        "me.proton.pass.electron",
    ]

    private enum Key {
        static let plainText = "plainTextByDefault"
        static let skipSecrets = "skipSecrets"
        static let linkPreviews = "linkPreviews"
        static let retentionDays = "retentionDays"
        static let ignoredApps = "ignoredBundleIDs"
        static let paused = "isPaused"
        static let openShortcut = "openShortcut"
        static let stackShortcut = "stackShortcut"
        static let welcomed = "hasShownWelcome"
        static let promptedForAccessibility = "hasPromptedForAccessibility"
    }

    @ObservationIgnored private let defaults = AppEnvironment.defaults
    @ObservationIgnored var onShortcutsChanged: (() -> Void)?
    @ObservationIgnored var onRetentionChanged: (() -> Void)?
    @ObservationIgnored var onPausedChanged: (() -> Void)?

    var plainTextByDefault: Bool { didSet { defaults.set(plainTextByDefault, forKey: Key.plainText) } }
    var skipSecrets: Bool { didSet { defaults.set(skipSecrets, forKey: Key.skipSecrets) } }
    var linkPreviews: Bool { didSet { defaults.set(linkPreviews, forKey: Key.linkPreviews) } }
    var retentionDays: Int {
        didSet {
            defaults.set(retentionDays, forKey: Key.retentionDays)
            onRetentionChanged?()
        }
    }
    var ignoredBundleIDs: [String] { didSet { defaults.set(ignoredBundleIDs, forKey: Key.ignoredApps) } }
    var isPaused: Bool {
        didSet {
            defaults.set(isPaused, forKey: Key.paused)
            onPausedChanged?()
        }
    }
    var openShortcut: KeyCombo? {
        didSet {
            save(openShortcut, forKey: Key.openShortcut)
            onShortcutsChanged?()
        }
    }
    var stackShortcut: KeyCombo? {
        didSet {
            save(stackShortcut, forKey: Key.stackShortcut)
            onShortcutsChanged?()
        }
    }
    /// A registered hotkey would fire instead of being recorded, so they're off while a new one is typed.
    @ObservationIgnored var isRecordingShortcut = false {
        didSet { onShortcutsChanged?() }
    }
    var hasShownWelcome: Bool { didSet { defaults.set(hasShownWelcome, forKey: Key.welcomed) } }
    var hasPromptedForAccessibility: Bool {
        didSet { defaults.set(hasPromptedForAccessibility, forKey: Key.promptedForAccessibility) }
    }

    private init() {
        let defaults = AppEnvironment.defaults
        defaults.register(defaults: [Key.skipSecrets: true])
        plainTextByDefault = defaults.bool(forKey: Key.plainText)
        skipSecrets = defaults.bool(forKey: Key.skipSecrets)
        linkPreviews = defaults.bool(forKey: Key.linkPreviews)
        retentionDays = defaults.integer(forKey: Key.retentionDays)
        ignoredBundleIDs = defaults.stringArray(forKey: Key.ignoredApps) ?? Self.defaultIgnoredApps
        isPaused = defaults.bool(forKey: Key.paused)
        hasShownWelcome = defaults.bool(forKey: Key.welcomed)
        hasPromptedForAccessibility = defaults.bool(forKey: Key.promptedForAccessibility)
        openShortcut = Self.load(Key.openShortcut, default: KeyCombo.defaultOpen, from: defaults)
        stackShortcut = Self.load(Key.stackShortcut, default: KeyCombo.defaultStack, from: defaults)
    }

    // An absent key means "use the default"; a cleared shortcut is stored as an empty value.
    private static func load(_ key: String, default fallback: KeyCombo, from defaults: UserDefaults) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return fallback }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    private func save(_ combo: KeyCombo?, forKey key: String) {
        defaults.set(combo.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }
}
