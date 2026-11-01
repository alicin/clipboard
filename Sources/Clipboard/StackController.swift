import AppKit
import Observation
import ClipboardCore
import SwiftUI

struct StackEntry: Identifiable, Equatable {
    let id = UUID()
    let clip: Clip
}

/// Copy several things in order, then paste them one at a time with ⌘V, oldest first.
@MainActor @Observable
final class StackController {
    private(set) var entries: [StackEntry] = []
    private(set) var isActive = false
    private(set) var isPresented = false
    private(set) var canDetectPaste = false

    @ObservationIgnored private let writer: PasteboardWriter
    @ObservationIgnored private let toast: ToastController
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored private var hideWork: DispatchWorkItem?
    @ObservationIgnored var onChange: ((_ isActive: Bool, _ count: Int) -> Void)?

    fileprivate static let width: CGFloat = 300
    fileprivate static let margin: CGFloat = 22
    fileprivate static let headerHeight: CGFloat = 46
    fileprivate static let rowHeight: CGFloat = 34
    fileprivate static let maxVisibleRows = 7
    fileprivate static let emptyHeight: CGFloat = 96
    fileprivate static let hintHeight: CGFloat = 92

    init(writer: PasteboardWriter, toast: ToastController) {
        self.writer = writer
        self.toast = toast
    }

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        entries = []
        installTapIfPossible()
        showPanel()
        notify()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        removeTap()
        withAnimation(.easeIn(duration: 0.14)) { isPresented = false }
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.entries = []
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        notify()
    }

    func add(_ clip: Clip) {
        if !isActive { start() }
        withAnimation(Motion.bouncy) { entries.append(StackEntry(clip: clip)) }
        installTapIfPossible()
        restoreHead()
        resizePanel()
        notify()
    }

    func remove(_ entry: StackEntry) {
        guard let index = entries.firstIndex(of: entry) else { return }
        _ = withAnimation(Motion.snappy) { entries.remove(at: index) }
        if index == 0 { restoreHead() }
        resizePanel()
        notify()
    }

    /// Keeps the next item on the pasteboard, since each new copy or direct paste overwrites it.
    func restoreHead() {
        guard isActive, let head = entries.first else { return }
        writer.write(head.clip, plainText: false)
    }

    func advance() {
        guard isActive, !entries.isEmpty else { return }
        _ = withAnimation(Motion.snappy) { entries.removeFirst() }
        notify()
        if entries.isEmpty {
            stop()
            toast.show("Paste Stack finished", symbol: "checkmark.circle.fill")
        } else {
            restoreHead()
            resizePanel()
        }
    }

    func requestAccessibility() {
        Paster.requestTrust()
    }

    func recheckAccessibility() {
        installTapIfPossible()
        resizePanel()
    }

    private func notify() {
        onChange?(isActive, entries.count)
    }

    private func installTapIfPossible() {
        if AppEnvironment.isDemo {
            canDetectPaste = true
            return
        }
        guard tap == nil else {
            canDetectPaste = true
            return
        }
        guard Paster.isTrusted, !AppEnvironment.isUITest else {
            canDetectPaste = false
            return
        }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<StackController>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { controller.handleTapEvent(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue), callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            canDetectPaste = false
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        tapSource = source
        canDetectPaste = true
    }

    private func removeTap() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown,
            event.getIntegerValueField(.eventSourceUserData) != Paster.syntheticEventMarker,
            event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
            event.getIntegerValueField(.keyboardEventKeycode) == Int64(KeyLayout.keyCode(for: "v"))
        else { return }
        let relevant = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        guard relevant == .maskCommand else { return }
        // Long enough for the target app to read the pasteboard before the next item replaces it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.advance() }
    }

    private var contentHeight: CGFloat {
        let rows = min(entries.count, Self.maxVisibleRows)
        let body = entries.isEmpty ? Self.emptyHeight : CGFloat(rows) * Self.rowHeight + 14
        return Self.headerHeight + body + (canDetectPaste ? 0 : Self.hintHeight)
    }

    private func panelFrame(topRight: NSPoint) -> NSRect {
        let width = Self.width + Self.margin * 2
        let height = contentHeight + Self.margin * 2
        return NSRect(x: topRight.x - width, y: topRight.y - height, width: width, height: height)
    }

    private func showPanel() {
        hideWork?.cancel()
        if AppEnvironment.isDemo {
            withAnimation(Motion.bouncy) { isPresented = true }
            return
        }
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configureFloatingPanel(panel, level: .floating, accessibilityLabel: "Paste Stack")
            panel.becomesKeyOnlyIfNeeded = true
            let hosting = NSHostingView(rootView: StackRoot(stack: self))
            hosting.sizingOptions = []
            panel.contentView = hosting
            self.panel = panel
            let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            panel.setFrame(AppEnvironment.placed(panelFrame(topRight: NSPoint(x: area.maxX - 4, y: area.maxY - 4))), display: false)
        } else {
            resizePanel()
        }
        panel?.orderFront(nil)
        DispatchQueue.main.async { [weak self] in
            withAnimation(Motion.bouncy) { self?.isPresented = true }
        }
    }

    /// Keeps the window hugging the card, so its clear part can't swallow clicks meant for the app beneath.
    /// It grows at once but shrinks after the spring settles, or the card would be cut off on its way down.
    private func resizePanel() {
        guard let panel, isActive else { return }
        if contentHeight + Self.margin * 2 >= panel.frame.height {
            applyPanelFrame()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.applyPanelFrame() }
        }
    }

    private func applyPanelFrame() {
        guard let panel else { return }
        let current = panel.frame
        panel.setFrame(panelFrame(topRight: NSPoint(x: current.maxX, y: current.maxY)), display: true)
    }
}

struct StackRoot: View {
    let stack: StackController

    var body: some View {
        VStack(spacing: 0) {
            StackCard(stack: stack)
                .frame(width: StackController.width)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .glassSurface(cornerRadius: 22)
                .scaleEffect(stack.isPresented ? 1 : 0.9, anchor: .topTrailing)
                .opacity(stack.isPresented ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(StackController.margin)
        .tint(Theme.accent)
    }
}

private struct StackCard: View {
    let stack: StackController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(Theme.accentDeep)
                    .symbolEffect(.bounce, value: stack.entries.count)
                Text("Paste Stack").font(.system(size: 13.5, weight: .semibold))
                if !stack.entries.isEmpty {
                    Text("\(stack.entries.count)")
                        .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button {
                    stack.stop()
                } label: {
                    Text("End")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: StackController.headerHeight)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())

            Rectangle().fill(.primary.opacity(0.1)).frame(height: 0.5)

            if stack.entries.isEmpty {
                VStack(spacing: 4) {
                    Text("Copy items in order")
                        .font(.system(size: 13, weight: .medium))
                    Text("Each ⌘V then pastes the next one, oldest first.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: StackController.emptyHeight)
                .transition(.opacity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(stack.entries.enumerated()), id: \.element.id) { index, entry in
                            StackRow(entry: entry, position: index + 1, isNext: index == 0) {
                                stack.remove(entry)
                            }
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.never)
                .frame(height: CGFloat(min(stack.entries.count, StackController.maxVisibleRows)) * StackController.rowHeight + 14)
            }

            if !stack.canDetectPaste {
                Rectangle().fill(.primary.opacity(0.1)).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow Accessibility access so each ⌘V moves to the next item.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        pillButton("Allow access", isPrimary: true) { stack.requestAccessibility() }
                        pillButton("Next item", isPrimary: false) { stack.advance() }
                            .opacity(stack.entries.isEmpty ? 0.4 : 1)
                            .disabled(stack.entries.isEmpty)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: StackController.hintHeight)
            }
        }
        .animation(Motion.snappy, value: stack.entries)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            if !stack.canDetectPaste { stack.recheckAccessibility() }
        }
    }

    private func pillButton(_ title: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isPrimary ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.primary))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(isPrimary ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.primary.opacity(0.08)), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct StackRow: View {
    let entry: StackEntry
    let position: Int
    let isNext: Bool
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            Text("\(position)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(isNext ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.secondary))
                .contentTransition(.numericText())
                .frame(width: 21, height: 21)
                .background(isNext ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.primary.opacity(0.08)), in: Circle())
            Text(label)
                .font(.system(size: 12.5, weight: isNext ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Remove from stack")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: StackController.rowHeight)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(Motion.snappy) { isHovering = hovering } }
    }

    private var label: String {
        if let title = entry.clip.title { return title }
        if entry.clip.kind == .image { return "Image, \(ClipFormat.footer(for: entry.clip))" }
        return entry.clip.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? entry.clip.kind.displayName
    }
}

@MainActor @Observable
final class ToastState {
    var message = ""
    var symbol = "checkmark.circle.fill"
    var isVisible = false
    var token = 0
}

@MainActor
final class ToastController {
    let state = ToastState()
    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?

    private static let size = NSSize(width: 520, height: 96)

    func show(_ message: String, symbol: String) {
        dismissal?.cancel()
        if AppEnvironment.isDemo {
            state.message = message
            state.symbol = symbol
            state.token += 1
            withAnimation(Motion.bouncy) { state.isVisible = true }
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        state.message = message
        state.symbol = symbol
        state.token += 1

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        panel.setFrame(
            AppEnvironment.placed(NSRect(x: area.midX - Self.size.width / 2, y: area.minY, width: Self.size.width, height: Self.size.height)),
            display: true)
        panel.orderFront(nil)
        DispatchQueue.main.async { [state] in
            withAnimation(Motion.bouncy) { state.isVisible = true }
        }

        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self else { return }
            withAnimation(.easeIn(duration: 0.18)) { self.state.isVisible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !self.state.isVisible { panel?.orderOut(nil) }
            }
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    #if DEBUG
    func hideForDemo() {
        withAnimation(.easeIn(duration: 0.18)) { state.isVisible = false }
    }
    #endif

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureFloatingPanel(panel, level: .statusBar)
        panel.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: ToastView(state: state))
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}

struct ToastView: View {
    let state: ToastState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accentDeep)
                .symbolEffect(.bounce, value: state.token)
            Text(state.message)
                .font(.system(size: 13, weight: .medium))
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 18)
        .frame(height: 42)
        .fixedSize()
        .glassSurface(cornerRadius: 21)
        .offset(y: state.isVisible ? 0 : 26)
        .scaleEffect(state.isVisible ? 1 : 0.88)
        .opacity(state.isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
