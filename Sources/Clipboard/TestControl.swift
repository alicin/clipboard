#if DEBUG
import AVKit
import AppKit
import Carbon.HIToolbox
import ClipboardCore

/// Drives the running app from scripts/ui_test.py in debug builds only. Events go through NSApp.sendEvent,
/// so they exercise the real monitors, responders and gestures without touching the user's focus or cursor.
@MainActor
final class TestControl {
    private let panel: PanelController
    private let stack: StackController
    private let settings: SettingsWindowController
    private var observer: NSObjectProtocol?
    private var pendingSnapshot: String?

    init(panel: PanelController, stack: StackController, settings: SettingsWindowController) {
        self.panel = panel
        self.stack = stack
        self.settings = settings
    }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.bunniesinc.clipboard.test"), object: nil, queue: .main
        ) { [weak self] notification in
            let line = notification.object as? String ?? ""
            MainActor.assumeIsolated { self?.run(line) }
        }
    }

    private var window: NSWindow? {
        NSApp.windows.first { $0 is KeyablePanel && $0.isVisible }
    }

    private func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return }
        let sequence = parts[0]
        let arguments = parts.count > 2 ? parts[2] : ""
        switch parts[1] {
        case "show": panel.show()
        case "hide": panel.hide()
        case "toggle": panel.toggle()
        case "settings": settings.show()
        case "stack": stack.toggle()
        case "appearance": NSApp.appearance = NSAppearance(named: arguments == "dark" ? .darkAqua : .aqua)
        case "key": sendKey(arguments)
        case "text": insertText(arguments)
        case "flags": sendFlags(arguments)
        case "click": sendClick(arguments)
        case "scroll": sendScroll(arguments)
        case "pin": pinSelected(toBoardNamed: arguments)
        case "stack-next": stack.advance()
        case "pause": Preferences.shared.isPaused = arguments == "on"
        case "secrets": Preferences.shared.secretHandling = SecretHandling(rawValue: arguments) ?? .skip
        case "hover": hoverCard(arguments)
        case "hotkey": sendHotKey(id: arguments == "stack" ? HotKeyID.stack : HotKeyID.open)
        case "rename-clip": if let clip = panel.model.selectedClip { panel.model.beginRename(clip) }
        case "rename-board": if let board = panel.model.pinboards.first(where: { $0.name == arguments }) { panel.model.beginRename(board) }
        case "delete-board": if let board = panel.model.pinboards.first(where: { $0.name == arguments }) { panel.model.beginDelete(board) }
        case "settings-page": settings.navigation.page = SettingsPage(rawValue: arguments) ?? .general
        case "settings-close": NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }?.performClose(nil)
        case "snapshot":
            // Rendered once the entrance animation has settled, just before the state is reported.
            pendingSnapshot = arguments
        case "drag-preview":
            if let clip = panel.model.selectedClip {
                renderDragPreview(of: clip, store: panel.model.store, boards: panel.model.pinboards, to: arguments)
            }
        case "state": break
        default: fputs("TestControl: unknown command \(parts[1])\n", stderr)
        }
        // Lets SwiftUI and detached store reads settle before reporting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.takePendingSnapshot()
            self?.writeState(sequence: sequence)
        }
    }

    private func modifiers(_ names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if names.contains("cmd") { flags.insert(.command) }
        if names.contains("shift") { flags.insert(.shift) }
        if names.contains("opt") { flags.insert(.option) }
        return flags
    }

    private func sendKey(_ arguments: String) {
        let parts = arguments.split(separator: " ").map(String.init)
        guard let first = parts.first, let code = UInt16(first) else { return }
        let characters = parts.count > 1 && parts[1].count == 1 ? parts[1] : ""
        post(code: code, characters: characters, flags: modifiers(parts))
    }

    /// A window that never becomes key gets no key events past the monitors, so text goes to the field editor directly.
    private func insertText(_ text: String) {
        guard let editor = window?.firstResponder as? NSTextView else { return }
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func post(code: UInt16, characters: String, flags: NSEvent.ModifierFlags) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { continue }
            NSApp.sendEvent(event)
        }
    }

    private func sendFlags(_ arguments: String) {
        guard
            let event = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: modifiers(arguments.split(separator: " ").map(String.init)),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)
        else { return }
        NSApp.sendEvent(event)
    }

    private func sendHotKey(id: UInt32) {
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event)
        var hotKeyID = EventHotKeyID(signature: HotKeyCenter.signature, id: id)
        SetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    /// `x y [clicks]`, in points from the shelf's top-left corner.
    private func sendClick(_ arguments: String) {
        let parts = arguments.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 2, let window else { return }
        let location = NSPoint(
            x: parts[0] + Metrics.shelfMargin, y: window.frame.height - Metrics.windowTopInset - parts[1])
        let clicks = parts.count > 2 ? Int(parts[2]) : 1
        for count in 1...clicks {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard
                    let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)
                else { continue }
                NSApp.sendEvent(event)
            }
        }
    }

    /// `x y deltaY`: a plain mouse wheel notch over the panel.
    private func sendScroll(_ arguments: String) {
        let parts = arguments.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 3, let window else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(parts[2]), wheel2: 0, wheel3: 0) else {
            return
        }
        let origin = window.frame.origin
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(
            x: origin.x + Metrics.shelfMargin + parts[0],
            y: screenHeight - (origin.y + window.frame.height - Metrics.windowTopInset - parts[1]))
        if let nsEvent = NSEvent(cgEvent: event) { NSApp.sendEvent(nsEvent) }
    }

    /// `minWidth maxWidth path`: renders the matching window to a PNG, wherever it is on screen.
    private func takePendingSnapshot() {
        guard let arguments = pendingSnapshot else { return }
        pendingSnapshot = nil
        let parts = arguments.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, let low = Double(parts[0]), let high = Double(parts[1]),
            let target = NSApp.windows.first(where: { $0.isVisible && (low...high).contains($0.frame.width) }),
            let view = target.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[2]))
    }

    /// `x y [index]`, in points from the top-left corner of the card at `index` or the selected one. Anything else stops hovering.
    private func hoverCard(_ arguments: String) {
        let parts = arguments.split(separator: " ").compactMap { Double($0) }
        let clips = panel.model.clips
        let clip = parts.count > 2 ? clips.dropFirst(Int(parts[2])).first : panel.model.selectedClip
        guard parts.count >= 2, let clip else {
            DemoControl.shared.hover = nil
            return
        }
        DemoControl.shared.hover = DemoControl.Hover(clipID: clip.id, point: CGPoint(x: parts[0], y: parts[1]))
    }

    private func pinSelected(toBoardNamed name: String) {
        let model = panel.model
        guard let clip = model.selectedClip, let board = model.pinboards.first(where: { $0.name == name }) else { return }
        model.togglePin(clip, board: board)
    }

    private var previewPlayerState: [String: Any] {
        func player(in view: NSView) -> AVPlayer? {
            if let view = view as? AVPlayerView { return view.player }
            return view.subviews.lazy.compactMap(player(in:)).first
        }
        let found = NSApp.windows.lazy.compactMap { $0.contentView.flatMap(player(in:)) }.first
        guard let found else { return ["exists": false] }
        return ["exists": true, "rate": found.rate, "seconds": found.currentTime().seconds, "failed": found.currentItem?.status == .failed]
    }

    private func writeState(sequence: String) {
        let model = panel.model
        let pasteboard = AppPasteboard.shared
        var scope = "history"
        switch model.scope {
        case .history: break
        case .suggested: scope = "suggested"
        case .pinboard(let id): scope = "pinboard:\(id)"
        }
        var edit = "none"
        if let current = model.edit { edit = String(describing: current) }
        let window = self.window
        let state: [String: Any] = [
            "sequence": sequence,
            "visible": panel.isVisible,
            "windowFound": window != nil,
            "isKey": window?.isKeyWindow ?? false,
            "firstResponder": window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil",
            "query": model.query,
            "scope": scope,
            "kind": model.kind?.rawValue ?? "all",
            "selectedIndex": model.clips.firstIndex { $0.id == model.selectedID } ?? -1,
            "selectedPreview": model.selectedClip?.preview ?? "",
            "clipCount": model.clips.count,
            "previews": model.clips.prefix(12).map { "\($0.kind.rawValue): \(($0.title ?? $0.preview ?? "").prefix(36))" },
            "boards": model.pinboards.map(\.name),
            "edit": edit,
            "isPreviewing": model.isPreviewing,
            "previewFramesShown": PreviewProbe.framesShown,
            "previewPlayer": previewPlayerState,
            "isPresented": model.isPresented,
            "commandHeld": model.commandHeld,
            "firstVisibleIndex": model.firstVisibleIndex,
            "stripOffset": model.stripScrollOffset,
            "targetApp": model.targetApp?.localizedName ?? "none",
            "stackActive": stack.isActive,
            "stackItems": stack.entries.map { String(($0.clip.preview ?? "").prefix(36)) },
            "canDetectPaste": stack.canDetectPaste,
            "pasteboardText": pasteboard.string(forType: .string) ?? "",
            "pasteboardTypes": pasteboard.types?.map(\.rawValue) ?? [],
            "trusted": Paster.isTrusted,
            "registeredHotKeys": HotKeyCenter.shared.registeredCount,
            "accessBehavior": NSPasteboard.general.accessBehavior.rawValue,
            "appIsActive": FocusTracker.shared.isPasteFrontmost,
            "settingsVisible": settings.isVisible,
            "windows": NSApp.windows.filter(\.isVisible).map { "\(Int($0.level.rawValue)) \(Int($0.frame.width))x\(Int($0.frame.height))" },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = ClipStore.defaultDirectory.appendingPathComponent("test-state.json")
        try? data.write(to: url, options: .atomic)
    }
}
#endif
