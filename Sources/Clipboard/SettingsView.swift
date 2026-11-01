import AppKit
import Observation
import ClipboardCore
import ServiceManagement
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, shortcuts, privacy, aiTools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .privacy: "Privacy"
        case .aiTools: "AI Tools"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "How Clipboard behaves day to day."
        case .shortcuts: "Keys for opening Clipboard and moving around the shelf."
        case .privacy: "What Clipboard saves, and what it never touches."
        case .aiTools: "Let tools like Claude search what you choose to share."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcuts: "command"
        case .privacy: "hand.raised.fill"
        case .aiTools: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .general: Theme.tileSlate
        case .shortcuts: Theme.tileSky
        case .privacy: Theme.tileMint
        case .aiTools: Theme.tileIris
        }
    }
}

@MainActor @Observable
final class SettingsNavigation {
    var page: SettingsPage = .general
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let navigation = SettingsNavigation()
    private let store: ClipStore
    private var window: NSWindow?

    init(store: ClipStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsRoot(store: store, navigation: navigation))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "Clipboard Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // An empty toolbar moves the window buttons down and in, so they sit inside the floating sidebar.
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unified
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 800, height: 600))
            window.center()
            self.window = window
        }
        if AppEnvironment.isHeadless {
            if let window { window.setFrame(AppEnvironment.placed(window.frame), display: false) }
            window?.orderFrontRegardless()
            return
        }
        // Plain activate() is only a request, and macOS declines it when the shelf or a hotkey opened Settings.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // An accessory app with no windows would otherwise keep focus away from whatever was underneath.
    func windowWillClose(_ notification: Notification) {
        FocusTracker.shared.returnFocus()
    }

    var isVisible: Bool { window?.isVisible ?? false }
}

struct SettingsRoot: View {
    let store: ClipStore
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(navigation: navigation)
            PageHost(store: store, page: navigation.page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Theme.accent)
        .ignoresSafeArea()
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Bindable var navigation: SettingsNavigation
    @Namespace private var selection

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Clipboard").font(.system(size: 16, weight: .semibold))
                    Text("Version \(version)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 50)
            .padding(.bottom, 14)

            ForEach(SettingsPage.allCases) { page in
                SidebarRow(page: page, isSelected: navigation.page == page, namespace: selection) {
                    withAnimation(Motion.snappy) { navigation.page = page }
                }
            }

            Spacer()
            CaptureStatusButton()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(width: 214)
        .frame(maxHeight: .infinity)
        .glassSurface(cornerRadius: 20)
        .padding(8)
    }
}

private struct SidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: page.symbol, tint: page.tint, size: 26)
                    .symbolEffect(.bounce, value: isSelected)
                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 38)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent.opacity(0.2))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 0.75)
                        }
                        .matchedGeometryEffect(id: "page", in: namespace)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.06))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct CaptureStatusButton: View {
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        Button {
            withAnimation(Motion.snappy) { preferences.isPaused.toggle() }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    if !preferences.isPaused {
                        Circle()
                            .fill(Theme.accent.opacity(0.35))
                            .frame(width: 16, height: 16)
                            .phaseAnimator([false, true]) { circle, grown in
                                circle.scaleEffect(grown ? 1.15 : 0.7).opacity(grown ? 0.15 : 0.5)
                            } animation: { _ in
                                Motion.isReduced ? nil : .easeInOut(duration: 1.3)
                            }
                    }
                    Circle()
                        .fill(preferences.isPaused ? Theme.tileSun : Theme.accentDeep)
                        .frame(width: 8, height: 8)
                }
                .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(preferences.isPaused ? "Paused" : "Saving clips")
                        .font(.system(size: 12, weight: .medium))
                        .contentTransition(.opacity)
                    Text(preferences.isPaused ? "Click to resume" : "Click to pause")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(tint.gradient)
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                            .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
                    }
                    .shadow(color: tint.opacity(0.35), radius: 3, y: 1.5)
            }
    }
}

// MARK: - Page layout

private struct PageHost: View {
    let store: ClipStore
    let page: SettingsPage

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title).font(.system(size: 26, weight: .bold))
                Text(page.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            switch page {
            case .general: GeneralPage(store: store)
            case .shortcuts: ShortcutsPage()
            case .privacy: PrivacyPage(store: store)
            case .aiTools: AIToolsPage(store: store)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 40)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(page)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
    }

    var body: some View {
        #if DEBUG
        if AppEnvironment.isDemo {
            Color.clear
                .overlay(alignment: .top) {
                    content
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: -DemoControl.shared.settingsScrollOffset)
                }
                .clipped()
        } else {
            scrollingPage
        }
        #else
        scrollingPage
        #endif
    }

    private var scrollingPage: some View {
        ScrollView {
            content
        }
        .scrollIndicators(.never)
    }
}

private struct SettingsCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 3)
            }
            VStack(spacing: 0) { content }
                .background(Theme.settingsCard, in: shape)
                .overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.03), radius: 3, y: 1)
        }
    }
}

private struct SettingRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 14)
            trailing
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.07)).frame(height: 0.5).padding(.leading, 55)
    }
}

private struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet, destructive }
    var kind: Kind = .quiet

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: kind == .quiet ? .medium : .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .frame(height: 28)
            .background(background, in: Capsule())
            .overlay {
                if kind == .quiet { Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
            }
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(Theme.onAccent)
        case .quiet: AnyShapeStyle(.primary)
        case .destructive: AnyShapeStyle(.white)
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(Theme.accentGradient)
        case .quiet: AnyShapeStyle(.primary.opacity(0.06))
        case .destructive: AnyShapeStyle(Color.red.gradient)
        }
    }
}

/// A capsule that slides between options, for choices that deserve more presence than a stock segmented control.
private struct SlidingTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = selection == option.value
                Button {
                    withAnimation(Motion.snappy) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if isSelected {
                                Capsule().fill(Theme.accentGradient).matchedGeometryEffect(id: "tab", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.primary.opacity(0.06), in: Capsule())
    }
}

// MARK: - General

private struct GeneralPage: View {
    let store: ClipStore
    @Bindable private var preferences = Preferences.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var isTrusted = Paster.isTrusted
    @State private var clipboardAccess = AppPasteboard.shared.accessBehavior
    @State private var isWaitingForAccess = false
    @State private var stats: StoreStats?
    @State private var breakdown: [KindBreakdown] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DirectPasteCard(isTrusted: isTrusted, isWaiting: isWaitingForAccess) {
                withAnimation(Motion.snappy) { isWaitingForAccess = true }
                Paster.requestTrust()
            }

            if clipboardAccess == .alwaysDeny || clipboardAccess == .ask {
                SettingsCard {
                    SettingRow(
                        symbol: "exclamationmark.triangle.fill", tint: Theme.tileSun,
                        title: clipboardAccess == .ask ? "macOS asks before every read" : "Clipboard can't read what you copy",
                        detail: "Set Clipboard to Allow under Paste from Other Apps in System Settings."
                    ) {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
                .transition(.opacity)
            }

            SettingsCard(title: "Everyday") {
                SettingRow(
                    symbol: "textformat", tint: Theme.tileSky, title: "Paste as plain text",
                    detail: "Hold ⇧ when you press ↩ to do the opposite."
                ) {
                    Toggle("", isOn: $preferences.plainTextByDefault).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingRow(
                    symbol: "power", tint: Theme.tileMint, title: "Open at login",
                    detail: launchError ?? "Start Clipboard when you log in."
                ) {
                    Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                }
                RowDivider()
                SettingRow(
                    symbol: "clock.arrow.circlepath", tint: Theme.tileIris, title: "Keep history",
                    detail: "Older clips are deleted for good. Pinned clips always stay."
                ) {
                    Picker("", selection: $preferences.retentionDays) {
                        Text("Forever").tag(0)
                        Text("1 year").tag(365)
                        Text("3 months").tag(90)
                        Text("1 month").tag(30)
                        Text("1 week").tag(7)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if let stats {
                LibraryCard(stats: stats, breakdown: breakdown)
            }
        }
        .onAppear { refresh() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        let trusted = Paster.isTrusted
        if trusted != isTrusted {
            withAnimation(Motion.bouncy) {
                isTrusted = trusted
                isWaitingForAccess = false
            }
        }
        clipboardAccess = AppPasteboard.shared.accessBehavior
        let newStats = try? store.stats()
        if newStats != stats {
            withAnimation(Motion.snappy) {
                stats = newStats
                breakdown = (try? store.kindBreakdown()) ?? []
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "Couldn't change this: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// The one setting that changes how Clipboard feels, so it leads the page until it's on, then steps back.
private struct DirectPasteCard: View {
    let isTrusted: Bool
    let isWaiting: Bool
    let onAllow: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        Group {
            if isTrusted {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 23))
                        .foregroundStyle(.white, Theme.accentDeep)
                        .symbolEffect(.bounce, value: isTrusted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Direct paste is on").font(.system(size: 13, weight: .semibold))
                        Text("Choosing a clip drops it straight into the app you're using.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Theme.accent.opacity(0.12), in: shape)
                .overlay { shape.strokeBorder(Theme.accent.opacity(0.45), lineWidth: 0.75) }
                .transition(.scale(scale: 0.97).combined(with: .opacity))
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 40, height: 40)
                            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .shadow(color: Theme.accent.opacity(0.45), radius: 6, y: 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Paste straight into your apps").font(.system(size: 14, weight: .semibold))
                            Text(
                                isWaiting
                                    ? "Turn on Clipboard in the Accessibility list. This updates by itself."
                                    : "Right now, choosing a clip only copies it, so you still press ⌘V."
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                        }
                        Spacer(minLength: 10)
                        if isWaiting {
                            ProgressView().controlSize(.small)
                                .transition(.scale.combined(with: .opacity))
                        }
                        Button(isWaiting ? "Ask again" : "Allow access", action: onAllow)
                            .buttonStyle(PillButtonStyle(kind: .primary))
                    }
                }
                .padding(14)
                .background(Theme.accent.opacity(0.1), in: shape)
                .overlay { shape.strokeBorder(Theme.accent.opacity(0.4), lineWidth: 0.75) }
                .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
    }
}

private struct LibraryCard: View {
    let stats: StoreStats
    let breakdown: [KindBreakdown]
    @State private var hasAppeared = false

    var body: some View {
        SettingsCard(title: "Your library") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    stat(value: stats.clipCount.formatted(), label: stats.clipCount == 1 ? "clip" : "clips")
                    stat(value: ClipFormat.byteCount(stats.totalBytes), label: "on this Mac")
                    Spacer()
                }
                if !breakdown.isEmpty {
                    bar
                    legend
                }
            }
            .padding(14)
        }
        .onAppear {
            withAnimation(Motion.bouncy.delay(0.1)) { hasAppeared = true }
        }
    }

    private func stat(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var bar: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(breakdown) { part in
                    Rectangle()
                        .fill(part.kind.tint.gradient)
                        .frame(width: max(3, proxy.size.width * CGFloat(part.count) / CGFloat(max(stats.clipCount, 1)) - 2))
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
        }
        .frame(height: 9)
        .clipShape(Capsule())
        .scaleEffect(x: hasAppeared ? 1 : 0, anchor: .leading)
    }

    private var legend: some View {
        HStack(spacing: 13) {
            ForEach(breakdown) { part in
                HStack(spacing: 5) {
                    Circle().fill(part.kind.tint).frame(width: 7, height: 7)
                    Text("\(part.kind.pluralName) \(part.count.formatted())")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPage: View {
    @Bindable private var preferences = Preferences.shared

    private let shelfKeys: [(keys: [String], label: String)] = [
        (["Type"], "Search everything"),
        (["←", "→"], "Move between clips"),
        (["↩"], "Paste"),
        (["⇧", "↩"], "Paste as plain text"),
        (["⌘", "1–9"], "Paste a visible clip"),
        (["Space"], "Preview"),
        (["⌘", "C"], "Copy without pasting"),
        (["⌘", "⌫"], "Delete"),
        (["⇥"], "Next pinboard"),
        (["⎋"], "Close"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Anywhere on your Mac") {
                SettingRow(
                    symbol: "rectangle.bottomthird.inset.filled", tint: Theme.accentDeep, title: "Open Clipboard",
                    detail: "Shows or hides the shelf."
                ) {
                    ShortcutField(combo: $preferences.openShortcut, id: "open")
                }
                RowDivider()
                SettingRow(
                    symbol: "square.stack.3d.up.fill", tint: Theme.tileSky,
                    title: "Paste Stack", detail: "Starts or ends a stack."
                ) {
                    ShortcutField(combo: $preferences.stackShortcut, id: "stack")
                }
            }
            Text("Click a shortcut, then type a new one. ⌫ clears it and ⎋ cancels.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.leading, 3)
                .padding(.top, -12)

            SettingsCard(title: "On the shelf") {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                    ForEach(shelfKeys, id: \.label) { entry in
                        HStack(spacing: 8) {
                            HStack(spacing: 3) {
                                ForEach(entry.keys, id: \.self) { Keycap(text: $0, isSmall: true) }
                            }
                            .frame(minWidth: 58, alignment: .leading)
                            Text(entry.label).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
            }
        }
    }
}

private struct ShortcutField: View {
    @Binding var combo: KeyCombo?
    let id: String
    @State private var isRecording = false
    @State private var shakeCount = 0

    var body: some View {
        Button {
            withAnimation(Motion.snappy) { isRecording = true }
        } label: {
            HStack(spacing: 3) {
                if isRecording {
                    Text("Type a shortcut")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accentDeep)
                        .phaseAnimator([1.0, 0.45]) { text, opacity in
                            text.opacity(opacity)
                        } animation: { _ in
                            Motion.isReduced ? nil : .easeInOut(duration: 0.7)
                        }
                        .transition(.opacity)
                } else if let combo {
                    ForEach(combo.parts, id: \.self) { part in
                        Keycap(text: part)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                } else {
                    Text("Not set")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 96, minHeight: 36)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isRecording ? AnyShapeStyle(Theme.accent.opacity(0.12)) : AnyShapeStyle(.clear))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isRecording ? AnyShapeStyle(Theme.ringGradient) : AnyShapeStyle(.clear), lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            KeyCatcher(
                isActive: isRecording,
                onKey: handle(_:),
                onCancel: { finishRecording() })
        }
        .modifier(ShakeEffect(travel: 5, trigger: CGFloat(shakeCount)))
        .animation(.linear(duration: 0.34), value: shakeCount)
        .animation(Motion.bouncy, value: combo)
        .onChange(of: isRecording) { _, recording in
            Preferences.shared.isRecordingShortcut = recording
        }
        #if DEBUG
        .onChange(of: DemoControl.shared.recordingShortcut) { _, recording in
            withAnimation(Motion.snappy) { isRecording = recording == id }
        }
        #endif
        .accessibilityLabel(combo?.display ?? "Not set")
    }

    private func finishRecording() {
        withAnimation(Motion.snappy) { isRecording = false }
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 53:
            finishRecording()
        case 51:
            combo = nil
            finishRecording()
        default:
            if let newCombo = KeyCombo(event: event) {
                combo = newCombo
                finishRecording()
            } else {
                shakeCount += 1
            }
        }
    }
}

private struct ShakeEffect: GeometryEffect {
    let travel: CGFloat
    var trigger: CGFloat

    var animatableData: CGFloat {
        get { trigger }
        set { trigger = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(trigger * .pi * 4), y: 0))
    }
}

private struct KeyCatcher: NSViewRepresentable {
    let isActive: Bool
    let onKey: (NSEvent) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        KeyCatcherView()
    }

    func updateNSView(_ view: KeyCatcherView, context: Context) {
        view.onKey = onKey
        view.onCancel = onCancel
        view.setActive(isActive)
    }
}

private final class KeyCatcherView: NSView {
    var onKey: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?
    private var isActive = false

    override var acceptsFirstResponder: Bool { isActive }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if active {
                window.makeFirstResponder(self)
            } else if window.firstResponder === self {
                window.makeFirstResponder(nil)
            }
        }
    }

    override func resignFirstResponder() -> Bool {
        if isActive { onCancel?() }
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if isActive { onKey?(event) } else { super.keyDown(with: event) }
    }

    // ⌘ shortcuts arrive here, not in keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isActive else { return super.performKeyEquivalent(with: event) }
        onKey?(event)
        return true
    }
}

// MARK: - Privacy

private struct PrivacyPage: View {
    let store: ClipStore
    @Bindable private var preferences = Preferences.shared
    @State private var isConfirmingDelete = false
    @State private var lastDeleted: Int?

    private var installedIgnored: [String] {
        preferences.ignoredBundleIDs.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    private var ignoredFootnote: String {
        let uninstalled = preferences.ignoredBundleIDs.count - installedIgnored.count
        let privateCopies = "Copies an app marks as private are never read."
        switch uninstalled {
        case 0: return privateCopies
        case 1: return "1 more app is skipped if you install it. \(privateCopies)"
        default: return "\(uninstalled) more apps are skipped if you install them. \(privateCopies)"
        }
    }

    private var secretsDetail: String {
        switch preferences.secretHandling {
        case .skip: "Left out of your history, so it can't be pasted later."
        case .hide: "Saved, but shown as dots. Pasting gives the real text."
        case .show: "Saved and shown in your history like any other clip."
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 3)
            .padding(.top, -12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "What gets saved") {
                SettingRow(
                    symbol: "pause.fill", tint: Theme.tileSun, title: "Pause saving",
                    detail: "Nothing new is saved until you turn this off."
                ) {
                    Toggle("", isOn: $preferences.isPaused).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingRow(
                    symbol: "key.fill", tint: Theme.tileMint, title: "Text that looks like a secret",
                    detail: secretsDetail
                ) {
                    SlidingTabs(
                        selection: $preferences.secretHandling,
                        options: [(.skip, "Skip"), (.hide, "Hide"), (.show, "Show")])
                }
                RowDivider()
                SettingRow(
                    symbol: "link", tint: Theme.tileSky, title: "Show link previews",
                    detail: "Clipboard visits links you copy to fetch a title, image and icon, and the site can see that. Private and single-use links are skipped."
                ) {
                    Toggle("", isOn: $preferences.linkPreviews).labelsHidden().toggleStyle(.switch)
                }
            }
            footnote("Secrets are API keys, tokens, private keys and card numbers. Clipboard only spots known formats, so it won't catch everything.")

            SettingsCard(title: "Never save from these apps") {
                ForEach(installedIgnored, id: \.self) { bundleID in
                    IgnoredAppRow(bundleID: bundleID) {
                        withAnimation(Motion.snappy) { preferences.ignoredBundleIDs.removeAll { $0 == bundleID } }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    RowDivider()
                }
                HStack {
                    Button {
                        addApp()
                    } label: {
                        Label("Add app", systemImage: "plus")
                    }
                    .buttonStyle(PillButtonStyle())
                    Spacer()
                }
                .padding(10)
            }
            footnote(ignoredFootnote)

            SettingsCard(title: "Your data") {
                SettingRow(
                    symbol: "internaldrive.fill", tint: Theme.tileSlate, title: "Stored only on this Mac",
                    detail: "In a folder only your account can read."
                ) {
                    EmptyView()
                }
                RowDivider()
                deleteRow
            }
        }
    }

    @ViewBuilder private var deleteRow: some View {
        Group { deleteRowContent }
        #if DEBUG
        .onChange(of: DemoControl.shared.confirmDeleteHistory) { _, confirming in
            withAnimation(Motion.snappy) { isConfirmingDelete = confirming }
        }
        #endif
    }

    @ViewBuilder private var deleteRowContent: some View {
        if isConfirmingDelete {
            VStack(alignment: .leading, spacing: 10) {
                Text("Delete your clipboard history? This can't be undone.")
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 7) {
                    Button("Keep everything") {
                        withAnimation(Motion.snappy) { isConfirmingDelete = false }
                    }
                    .buttonStyle(PillButtonStyle())
                    Spacer()
                    Button("Delete all but pinned") { clear(keepPinned: true) }
                        .buttonStyle(PillButtonStyle())
                    Button("Delete everything") { clear(keepPinned: false) }
                        .buttonStyle(PillButtonStyle(kind: .destructive))
                }
            }
            .padding(13)
            .background(Color.red.opacity(0.07))
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        } else {
            SettingRow(
                symbol: "trash.fill", tint: .red, title: "Delete history",
                detail: lastDeleted.map { $0 == 1 ? "Deleted 1 clip." : "Deleted \($0.formatted()) clips." } ?? "Remove saved clips from this Mac."
            ) {
                Button("Delete…") {
                    withAnimation(Motion.snappy) { isConfirmingDelete = true }
                }
                .buttonStyle(PillButtonStyle())
            }
            .transition(.opacity)
        }
    }

    private func clear(keepPinned: Bool) {
        let removed = (try? store.clearHistory(keepPinned: keepPinned)) ?? 0
        NotificationCenter.default.post(name: .clipsChanged, object: nil)
        withAnimation(Motion.snappy) {
            lastDeleted = removed
            isConfirmingDelete = false
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                !preferences.ignoredBundleIDs.contains(bundleID)
            else { continue }
            withAnimation(Motion.snappy) { preferences.ignoredBundleIDs.append(bundleID) }
        }
    }
}

private struct IgnoredAppRow: View {
    let bundleID: String
    let onRemove: () -> Void
    @State private var isHovering = false

    private var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    var body: some View {
        HStack(spacing: 12) {
            if let appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
                Text(FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: ""))
                    .font(.system(size: 13, weight: .medium))
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help("Allow saving from this app")
            .accessibilityLabel("Allow saving from this app")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
    }
}

// MARK: - AI tools

private struct AIToolsPage: View {
    let store: ClipStore
    @State private var access: AIAccess = .off
    @State private var tool = 0
    @Namespace private var selection

    private var helperPath: String {
        if AppEnvironment.isDemo { return "/Applications/Clipboard.app/Contents/MacOS/clipboard-mcp" }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/clipboard-mcp").path
    }

    private var snippet: String {
        tool == 0
            ? "claude mcp add clipboard -- \"\(helperPath)\""
            : """
            {
              "mcpServers": {
                "clipboard": {
                  "command": "\(helperPath)"
                }
              }
            }
            """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                choice(.off, title: "Nothing", detail: "Tools can't read anything.", symbol: "nosign", tint: Theme.tileSlate)
                choice(.pinboards, title: "Pinboards", detail: "Only clips you've pinned.", symbol: "pin.fill", tint: Theme.tileSky)
                choice(.everything, title: "Everything", detail: "Your whole history.", symbol: "tray.full.fill", tint: Theme.accentDeep)
            }
            Text("Connected tools can search and read what you share here, and anything they read goes to whichever service that tool uses. They can't change your clips or your clipboard, and they never get text that looks like a secret. Changes apply right away.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 3)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Connect a tool").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    SlidingTabs(selection: $tool, options: [(0, "Claude Code"), (1, "Other MCP apps")])
                }
                .padding(.leading, 3)
                CodeBlock(text: snippet)
            }
        }
        .onAppear { access = (try? store.aiAccess()) ?? .off }
        #if DEBUG
        .onChange(of: DemoControl.shared.aiAccess) { _, value in
            guard let value else { return }
            withAnimation(Motion.bouncy) { access = value }
            try? store.setAIAccess(value)
        }
        #endif
    }

    private func choice(_ value: AIAccess, title: String, detail: String, symbol: String, tint: Color) -> some View {
        let isSelected = access == value
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            withAnimation(Motion.bouncy) { access = value }
            try? store.setAIAccess(value)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                IconTile(symbol: symbol, tint: tint)
                    .symbolEffect(.bounce, value: isSelected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.settingsCard, in: shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
            .overlay {
                if isSelected {
                    shape.strokeBorder(Theme.ringGradient, lineWidth: 2)
                        .matchedGeometryEffect(id: "access", in: selection)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct CodeBlock: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Color(white: 0.9))
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .padding(.trailing, 74)
            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            #if DEBUG
            .onChange(of: DemoControl.shared.copiedSnippet) {
                withAnimation(Motion.bouncy) { didCopy = true }
            }
            #endif
            .overlay(alignment: .topTrailing) {
                Button {
                    AppPasteboard.shared.clearContents()
                    AppPasteboard.shared.setString(text, forType: .string)
                    withAnimation(Motion.bouncy) { didCopy = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation(Motion.snappy) { didCopy = false }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                        Text(didCopy ? "Copied" : "Copy")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(didCopy ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(Color.white))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(didCopy ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.14)), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(8)
            }
    }
}
