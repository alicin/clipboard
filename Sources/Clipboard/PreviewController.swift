import AppKit
import ClipboardCore
import SwiftUI

@MainActor
final class PreviewController {
    private let model: PanelModel
    private var hideWork: DispatchWorkItem?
    private static let inset: CGFloat = 26

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureFloatingPanel(panel, level: .statusBar)
        let hosting = NSHostingView(rootView: PreviewRoot(model: model, inset: Self.inset))
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }()

    init(model: PanelModel) {
        self.model = model
    }

    func show(above shelf: NSRect) {
        hideWork?.cancel()
        let screen = NSScreen.screens.first { $0.frame.intersects(shelf) } ?? NSScreen.main
        let top = screen?.visibleFrame.maxY ?? shelf.maxY + 540
        let height = max(min(560, top - shelf.maxY - 24), 200)
        let width = min(760, shelf.width - 40)
        let frame = NSRect(x: shelf.midX - width / 2, y: shelf.maxY + 12, width: width, height: height)
        panel.setFrame(AppEnvironment.placed(frame.insetBy(dx: -Self.inset, dy: -Self.inset)), display: true)
        panel.orderFront(nil)
    }

    func hide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

struct PreviewRoot: View {
    let model: PanelModel
    let inset: CGFloat

    var body: some View {
        PreviewView(model: model)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .glassSurface(cornerRadius: 24)
            .scaleEffect(model.isPreviewing ? 1 : 0.94, anchor: .bottom)
            .offset(y: model.isPreviewing ? 0 : 18)
            .opacity(model.isPreviewing ? 1 : 0)
            .padding(inset)
            .tint(Theme.accent)
    }
}

private struct PreviewView: View {
    let model: PanelModel

    var body: some View {
        ZStack {
            Color.clear
            if let clip = model.selectedClip {
                VStack(alignment: .leading, spacing: 0) {
                    PreviewHeader(clip: clip)
                    Rectangle().fill(.primary.opacity(0.1)).frame(height: 0.5)
                    PreviewBody(clip: clip, store: model.store)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .id(clip.id)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.selectedID)
    }
}

private struct PreviewHeader: View {
    let clip: Clip

    var body: some View {
        let style = AppAppearance.shared.style(for: clip.source.bundleID)
        HStack(spacing: 11) {
            if let icon = style.icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.title ?? clip.linkTitle ?? clip.kind.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Keycap(text: "↩", isSmall: true)
                Text("Paste").font(.system(size: 12)).foregroundStyle(.secondary)
                Keycap(text: "Space", isSmall: true).padding(.leading, 6)
                Text("Close").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var subtitle: String {
        var parts = [ClipFormat.relativeTime(clip.sortedAt)]
        let footer = ClipFormat.footer(for: clip)
        if !footer.isEmpty { parts.append(footer) }
        if let name = clip.source.name { parts.insert(name, at: 0) }
        if clip.pasteCount > 0 { parts.append(clip.pasteCount == 1 ? "Pasted once" : "Pasted \(clip.pasteCount) times") }
        return parts.joined(separator: ", ")
    }
}

private struct PreviewBody: View {
    let clip: Clip
    let store: ClipStore
    @State private var text: String?
    @State private var image: NSImage?

    private static let displayLimit = 120_000

    var body: some View {
        // Color.clear keeps this view non-empty while loading: an empty view never appears, so .task wouldn't run.
        ZStack {
            Color.clear
            switch clip.kind {
            case .image:
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                        .padding(18)
                        .transition(.opacity)
                }
            case .color:
                let color = clip.preview.flatMap(ClipColor.parse)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(color?.swiftUIColor ?? .gray)
                    .overlay {
                        Text(colorDescription(color))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(color?.readableForeground ?? .white)
                            .multilineTextAlignment(.center)
                    }
                    .padding(18)
            case .file:
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(paths, id: \.self) { path in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 34, height: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                                    Text(path).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                }
            case .text, .link, .code:
                if let display {
                    ScrollView {
                        Text(display)
                            .font(clip.kind == .code ? .system(size: 12, design: .monospaced) : .system(size: 14))
                            .foregroundStyle(clip.kind == .code ? Color(white: 0.9) : Color.primary)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                    }
                    .background(clip.kind == .code ? Theme.codeBackground : .clear)
                    .transition(.opacity)
                } else if clip.preview == nil {
                    Text("This content can only be shown by \(clip.source.name ?? "the app it came from"). Pasting restores it in full.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(30)
                }
            }
        }
        .task(id: clip.uuid) {
            let store = store
            let clip = clip
            switch clip.kind {
            case .image:
                let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                    guard let payload = try? store.payload(for: clip) else { return nil }
                    return payload.joined().lazy.compactMap { NSImage(data: $0.data) }.first
                }.value
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            default:
                let loaded = await Task.detached(priority: .userInitiated) {
                    try? store.fullText(clipID: clip.id)
                }.value
                withAnimation(.easeOut(duration: 0.12)) { text = loaded }
            }
        }
    }

    private var paths: [String] {
        (text ?? clip.preview ?? "").split(separator: "\n").map(String.init)
    }

    private var display: String? {
        guard let text else { return nil }
        guard text.count > Self.displayLimit else { return text }
        return String(text.prefix(Self.displayLimit)) + "\n\n[Preview ends here. Pasting includes the full text.]"
    }

    private func colorDescription(_ color: ClipColor?) -> String {
        guard let color else { return clip.preview ?? "" }
        let channels = [color.red, color.green, color.blue].map { String(Int(($0 * 255).rounded())) }.joined(separator: ", ")
        return "\(color.hex)\nrgb(\(channels))"
    }
}
