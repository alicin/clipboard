import AppKit
import ApplicationServices
import ClipboardCore

enum Paster {
    /// Stamped on synthesised keystrokes so the Paste Stack's event tap can tell them from the user's own ⌘V.
    static let syntheticEventMarker: Int64 = 0x5053_5445

    static var isTrusted: Bool {
        #if DEBUG
        if AppEnvironment.isDemo { return MainActor.assumeIsolated { DemoControl.shared.isTrusted } }
        #endif
        return AXIsProcessTrusted()
    }

    /// An entry left by an earlier build can look switched on while macOS rejects this one, and it blocks
    /// the system prompt, so it's cleared first.
    static func requestTrust() {
        guard !AppEnvironment.isUITest, !isTrusted, let bundleID = Bundle.main.bundleIdentifier else { return }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", bundleID]
        try? reset.run()
        reset.waitUntilExit()
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func sendPasteKeystroke() {
        guard !AppEnvironment.isUITest else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keeps modifiers the user is still holding (⇧ from ⇧↩, ⌘ from ⌘1) out of the keystroke.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        let keyCode = KeyLayout.keyCode(for: "v")
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}

@MainActor
final class PasteCoordinator {
    private let store: ClipStore
    private let writer: PasteboardWriter
    private let preferences: Preferences
    private let toast: ToastController
    var stack: StackController?

    init(store: ClipStore, writer: PasteboardWriter, preferences: Preferences, toast: ToastController) {
        self.store = store
        self.writer = writer
        self.preferences = preferences
        self.toast = toast
    }

    func copy(_ clip: Clip) {
        if writer.write(clip, plainText: false) {
            toast.show("Copied", symbol: "checkmark.circle.fill")
        } else {
            toast.show(Self.missingMessage, symbol: "exclamationmark.triangle.fill")
        }
    }

    /// `invertFormatting` is the ⇧ variant: it flips whatever the "paste as plain text" preference says.
    func paste(_ clip: Clip, invertFormatting: Bool, into target: NSRunningApplication?) {
        let plain = preferences.plainTextByDefault != invertFormatting
        guard writer.write(clip, plainText: plain) else {
            toast.show(Self.missingMessage, symbol: "exclamationmark.triangle.fill")
            return
        }
        try? store.recordPaste(clipID: clip.id, targetBundleID: target?.bundleIdentifier)
        NotificationCenter.default.post(name: .clipsChanged, object: nil)

        guard Paster.isTrusted else {
            if !preferences.hasPromptedForAccessibility {
                preferences.hasPromptedForAccessibility = true
                Paster.requestTrust()
            }
            toast.show("Copied. Press ⌘V to paste.", symbol: "doc.on.clipboard.fill")
            return
        }

        // Only needed when Settings has made Clipboard the active app; the shelf never takes activation.
        var delay = 0.06
        if FocusTracker.shared.isPasteFrontmost {
            target?.activate()
            delay = 0.2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Paster.sendPasteKeystroke()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.stack?.restoreHead() }
        }
    }

    private static let missingMessage = "This clip's saved data is missing."
}
