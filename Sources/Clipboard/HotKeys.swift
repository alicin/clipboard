import AppKit
import Carbon.HIToolbox

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static var defaultOpen: KeyCombo {
        KeyCombo(keyCode: UInt32(KeyLayout.keyCode(for: "v")), carbonModifiers: UInt32(cmdKey | shiftKey))
    }

    static var defaultStack: KeyCombo {
        KeyCombo(keyCode: UInt32(KeyLayout.keyCode(for: "c")), carbonModifiers: UInt32(cmdKey | shiftKey))
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        // Shift alone would swallow capital letters everywhere.
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        keyCode = UInt32(event.keyCode)
        carbonModifiers = modifiers
    }

    var parts: [String] {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(KeyLayout.label(for: CGKeyCode(keyCode)))
        return parts
    }

    var display: String { parts.joined() }
}

enum KeyLayout {
    private static func layoutData() -> Data? {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for source in sources {
            guard let source = source?.takeRetainedValue(),
                let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        }
        return nil
    }

    private static func character(for keyCode: CGKeyCode, in layout: Data) -> String? {
        layout.withUnsafeBytes { buffer -> String? in
            guard let pointer = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                pointer, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    private static let qwertyFallback: [String: CGKeyCode] = ["v": CGKeyCode(kVK_ANSI_V), "c": CGKeyCode(kVK_ANSI_C)]

    /// Synthesised keystrokes and default hotkeys must follow the active layout: on Dvorak or Turkish F,
    /// the physical key that QWERTY calls V types something else.
    static func keyCode(for character: String) -> CGKeyCode {
        if let layout = layoutData() {
            for code in CGKeyCode(0)..<128 where self.character(for: code, in: layout)?.lowercased() == character {
                return code
            }
        }
        return qwertyFallback[character] ?? 0
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋", kVK_LeftArrow: "←",
        kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3",
        kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func label(for keyCode: CGKeyCode) -> String {
        if let special = specialKeys[Int(keyCode)] { return special }
        guard let layout = layoutData(), let character = character(for: keyCode, in: layout) else { return "?" }
        return character.uppercased()
    }
}

enum HotKeyID {
    static let open: UInt32 = 1
    static let stack: UInt32 = 2
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var isInstalled = false
    var registeredCount: Int { references.count }
    static let signature: OSType = 0x5053_5445

    private func installHandlerIfNeeded() {
        guard !isInstalled else { return }
        isInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr else { return status }
                let id = hotKeyID.id
                MainActor.assumeIsolated { HotKeyCenter.shared.handlers[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(id: UInt32, combo: KeyCombo?, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        if let existing = references.removeValue(forKey: id) { UnregisterEventHotKey(existing) }
        handlers[id] = handler
        guard let combo else { return true }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        references[id] = reference
        return true
    }
}
