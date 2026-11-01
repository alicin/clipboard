import AppKit
import Carbon.HIToolbox
import ClipboardCore
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { !AppEnvironment.isHeadless }
    override var canBecomeMain: Bool { false }
}

/// A borderless, transparent panel. The glass drawn by SwiftUI inside it is the only visible edge, so the
/// window has no shadow or background of its own that could show around the rounded corners.
@MainActor
func configureFloatingPanel(_ panel: NSPanel, level: NSWindow.Level, accessibilityLabel: String? = nil) {
    panel.level = level
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    if let accessibilityLabel { panel.setAccessibilityLabel(accessibilityLabel) }
}

/// Remembers the app the user was last in. The shelf needs it when Clipboard itself is frontmost, which
/// happens when it's opened from Spotlight or while Settings is open.
@MainActor
final class FocusTracker {
    static let shared = FocusTracker()
    private(set) var lastExternalApp: NSRunningApplication?
    private var observer: NSObjectProtocol?

    /// NSApp.isActive also reads true while a non-activating panel is key, even though the app underneath
    /// stays frontmost. This one only reads true when Clipboard has really taken over.
    var isPasteFrontmost: Bool { NSRunningApplication.current.isActive }

    func start() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            lastExternalApp = front
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier != ownPID
            else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = app }
        }
    }

    func returnFocus() {
        guard !AppEnvironment.isHeadless else { return }
        lastExternalApp?.activate()
    }
}

@MainActor
final class PanelController {
    let model: PanelModel
    private let panel: KeyablePanel
    private let preview: PreviewController
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var insideClickMonitor: Any?
    private var outsideClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var changeObserver: NSObjectProtocol?
    private var isShown = false

    private static let numberRowKeys = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5, kVK_ANSI_6: 6, kVK_ANSI_7: 7,
        kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    init(model: PanelModel) {
        self.model = model
        preview = PreviewController(model: model)

        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: Metrics.shelfHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // After isFloatingPanel, which resets the level to one that sits underneath the Dock.
        configureFloatingPanel(panel, level: .statusBar, accessibilityLabel: "Clipboard")
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true

        let hosting = NSHostingView(rootView: ShelfRoot(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting

        changeObserver = NotificationCenter.default.addObserver(forName: .clipsChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown else { return }
                self.model.refresh()
            }
        }
    }

    var isVisible: Bool { isShown }

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        guard !isShown else { return }
        isShown = true
        model.isDirectPasteEnabled = Paster.isTrusted
        model.isCapturePaused = Preferences.shared.isPaused
        model.isPresented = false
        model.prepareForShow(target: FocusTracker.shared.lastExternalApp)

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let full = screen?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let visible = screen?.visibleFrame ?? full
        // Reaches down over the Dock, so the shelf rises from the true bottom of the screen.
        let gap = visible.minY - full.minY + Metrics.shelfMargin
        model.bottomGap = gap
        panel.setFrame(
            AppEnvironment.placed(
                NSRect(
                    x: visible.minX, y: full.minY, width: visible.width,
                    height: gap + Metrics.shelfHeight + Metrics.windowTopInset)),
            display: false)

        if AppEnvironment.isHeadless {
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        installMonitors()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShown else { return }
            withAnimation(Motion.shelfIn) { self.model.isPresented = true }
        }
    }

    /// `completion` runs once the panel is off screen and no longer holds the keyboard.
    func hide(animated: Bool = true, completion: (() -> Void)? = nil) {
        guard isShown else {
            completion?()
            return
        }
        isShown = false
        removeMonitors()
        if model.isPreviewing { closePreview() }
        if FocusTracker.shared.isPasteFrontmost, !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            FocusTracker.shared.returnFocus()
        }

        let duration = animated && !Motion.isReduced ? 0.15 : 0
        guard duration > 0 else {
            model.isPresented = false
            panel.orderOut(nil)
            completion?()
            return
        }
        withAnimation(.easeIn(duration: duration)) { model.isPresented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            if !self.isShown { self.panel.orderOut(nil) }
            completion?()
        }
    }

    private var shelfFrame: NSRect {
        let window = panel.frame
        return NSRect(
            x: window.minX + Metrics.shelfMargin, y: window.minY + model.bottomGap,
            width: window.width - Metrics.shelfMargin * 2, height: Metrics.shelfHeight)
    }

    func togglePreview() {
        if model.isPreviewing {
            closePreview()
        } else {
            preview.show(above: shelfFrame)
            DispatchQueue.main.async { [weak self] in
                withAnimation(Motion.bouncy) { self?.model.isPreviewing = true }
            }
        }
    }

    private func closePreview() {
        withAnimation(.easeIn(duration: 0.12)) { model.isPreviewing = false }
        preview.hide(after: 0.12)
    }

    // MARK: Event routing

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return Self.horizontalScroll(from: event)
        }
        // The window extends past the visible shelf, and a click on its clear part counts as a click outside.
        insideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let shelf = self.shelfFrame.offsetBy(dx: -self.panel.frame.minX, dy: -self.panel.frame.minY)
            guard !shelf.contains(event.locationInWindow) else { return event }
            self.hide()
            return nil
        }
        guard !AppEnvironment.isHeadless else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isSelf = activated?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            MainActor.assumeIsolated {
                guard !isSelf else { return }
                self?.hide()
            }
        }
    }

    private func removeMonitors() {
        for monitor in [keyMonitor, scrollMonitor, insideClickMonitor, outsideClickMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        scrollMonitor = nil
        insideClickMonitor = nil
        outsideClickMonitor = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .flagsChanged {
            let held = flags.contains(.command)
            if held != model.commandHeld {
                withAnimation(Motion.snappy) { model.commandHeld = held }
            }
            return event
        }
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let keyCode = Int(event.keyCode)

        if model.edit != nil {
            switch keyCode {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                model.commitEdit()
                return nil
            case kVK_Escape:
                model.cancelEdit()
                return nil
            default:
                return event
            }
        }

        switch keyCode {
        case kVK_Escape:
            if model.isPreviewing {
                closePreview()
            } else if !model.query.isEmpty {
                model.query = ""
            } else {
                hide()
            }
            return nil
        case kVK_LeftArrow:
            command ? model.selectFirst() : model.moveSelection(by: -1)
            return nil
        case kVK_RightArrow:
            command ? model.selectLast() : model.moveSelection(by: 1)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.pasteSelected(invertFormatting: shift)
            return nil
        case kVK_Tab:
            model.cycleScope(by: shift ? -1 : 1)
            return nil
        case kVK_Space where model.query.isEmpty && !command:
            togglePreview()
            return nil
        case kVK_Delete where command:
            model.deleteSelected()
            return nil
        default:
            break
        }

        // By physical key: on layouts like AZERTY the top row only types digits with ⇧ held.
        if command, let number = Self.numberRowKeys[keyCode] {
            model.pasteVisible(number: number)
            return nil
        }
        guard command, let characters = event.charactersIgnoringModifiers?.lowercased() else { return event }
        switch characters {
        case "c":
            let editor = panel.firstResponder as? NSText
            guard editor?.selectedRange.length ?? 0 == 0 else { return event }
            if let clip = model.selectedClip { model.actions.copy(clip) }
            return nil
        case ",":
            model.actions.openSettings()
            return nil
        case "f":
            model.focusToken += 1
            return nil
        // The menu bar belongs to the app underneath, so ⌘W and ⌘Q here mean "dismiss", not "quit Clipboard".
        case "w", "q":
            hide()
            return nil
        default:
            return event
        }
    }

    /// A horizontal list should still scroll with a plain mouse wheel, so vertical deltas become horizontal.
    private static func horizontalScroll(from event: NSEvent) -> NSEvent {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let copy = event.cgEvent?.copy() else {
            return event
        }
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: copy.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        copy.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: copy.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
        copy.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: copy.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        return NSEvent(cgEvent: copy) ?? event
    }
}
