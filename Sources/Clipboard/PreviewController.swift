import AVKit
import AppKit
import ClipboardCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

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
                    PreviewBody(clip: clip, store: model.store, isActive: model.isPreviewing)
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
    /// The panel stays alive between previews, so anything that moves or makes a sound has to stop when this goes false.
    let isActive: Bool
    @State private var text: String?
    @State private var image: NSImage?
    @State private var movingImage: Data?
    @State private var playable: PlayableFile?

    private static let displayLimit = 120_000

    var body: some View {
        // Color.clear keeps this view non-empty while loading: an empty view never appears, so .task wouldn't run.
        ZStack {
            Color.clear
            if clip.isHidden {
                VStack(spacing: 12) {
                    Text(Clip.hiddenPreview)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .tracking(2.5)
                    Text("Hidden because it looks like a secret. Pasting gives the real text.")
                        .font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(30)
            } else {
                content
            }
        }
        .task(id: "\(clip.uuid)-\(clip.isHidden)") {
            guard !clip.isHidden else { return }
            let store = store
            let clip = clip
            switch clip.kind {
            case .image:
                let loaded = await Task.detached(priority: .userInitiated) { () -> Picture? in
                    guard let payload = try? store.payload(for: clip) else { return nil }
                    return Picture(representations: payload.joined().map(\.data))
                }.value
                withAnimation(.easeOut(duration: 0.15)) {
                    image = loaded?.image
                    movingImage = loaded?.moving
                }
            default:
                let loaded = await Task.detached(priority: .userInitiated) {
                    try? store.fullText(clipID: clip.id)
                }.value
                withAnimation(.easeOut(duration: 0.12)) { text = loaded }
                if clip.kind == .file, clip.itemCount == 1, let path = paths.first { await loadMedia(at: path) }
            }
        }
    }

    private func loadMedia(at path: String) async {
        let url = URL(fileURLWithPath: path)
        guard let type = UTType(filenameExtension: url.pathExtension), FileManager.default.fileExists(atPath: path) else { return }
        if type.conforms(to: .audiovisualContent) {
            let loaded = await PlayableFile(url: url)
            withAnimation(.easeOut(duration: 0.15)) { playable = loaded }
        } else if type.conforms(to: .image) {
            let loaded = await Task.detached(priority: .userInitiated) { () -> Picture? in
                (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap { Picture(representations: [$0]) }
            }.value
            withAnimation(.easeOut(duration: 0.15)) {
                image = loaded?.image
                movingImage = loaded?.moving
            }
        }
    }

    @ViewBuilder private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            if let movingImage, let image {
                MovingImage(data: movingImage, poster: image, isActive: isActive)
            } else if let image {
                Image(nsImage: image).resizable().scaledToFit()
            }
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .padding(18)
        .transition(.opacity)
    }

    @ViewBuilder private func player(_ file: PlayableFile) -> some View {
        // Not kept while closed: dropping the view is what stops the sound.
        if isActive {
            if let size = file.videoSize {
                PlayerView(url: file.url)
                    .aspectRatio(size, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    .padding(18)
            } else {
                VStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 96, height: 96)
                    Text(file.url.lastPathComponent).font(.system(size: 14, weight: .medium))
                    PlayerView(url: file.url)
                        .frame(maxWidth: 420, maxHeight: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(18)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch clip.kind {
        case .image:
            picture
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
        case .file where playable != nil:
            if let playable { player(playable) }
        case .file where image != nil:
            picture
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

/// A picture ready to show, and its original bytes if it has more than one frame.
private struct Picture: @unchecked Sendable {
    let image: NSImage
    let moving: Data?

    // An app may offer a flat copy next to the original, so the moving one wins wherever it sits.
    init?(representations: [Data]) {
        let moving = representations.first(where: Self.isMoving)
        guard let image = moving.flatMap(NSImage.init(data:)) ?? representations.lazy.compactMap(NSImage.init(data:)).first else {
            return nil
        }
        self.image = image
        self.moving = moving
    }

    private static func isMoving(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 1,
            let type = CGImageSourceGetType(source) as String?
        else { return false }
        // A multi-page TIFF also has several frames, but those are pages.
        return type != UTType.tiff.identifier
    }
}

private struct MovingImage: View {
    let data: Data
    let poster: NSImage
    let isActive: Bool
    @State private var frame: CGImage?
    @State private var stopper = AnimationStopper()

    var body: some View {
        Group {
            if let frame {
                Image(decorative: frame, scale: 1).resizable().scaledToFit()
            } else {
                Image(nsImage: poster).resizable().scaledToFit()
            }
        }
        .onChange(of: isActive, initial: true) { _, active in
            stopper.isStopped = true
            guard active else { return }
            let next = AnimationStopper()
            stopper = next
            CGAnimateImageDataWithBlock(data as CFData, nil) { _, image, stop in
                #if DEBUG
                PreviewProbe.framesShown += 1
                #endif
                frame = image
                if next.isStopped { stop.pointee = true }
            }
        }
        .onDisappear { stopper.isStopped = true }
    }
}

private final class AnimationStopper {
    var isStopped = false
}

#if DEBUG
enum PreviewProbe {
    nonisolated(unsafe) static var framesShown = 0
}
#endif

private struct PlayableFile: Equatable {
    let url: URL
    /// Nil for a file that's only sound.
    let videoSize: CGSize?

    /// Nil when AVFoundation can't play the file, as with most WebM and MKV, which then gets the plain file row.
    init?(url: URL) async {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return nil }
        self.url = url
        var size: CGSize?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
            let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let turned = natural.applying(transform)
            size = CGSize(width: abs(turned.width), height: abs(turned.height))
        }
        videoSize = size
    }
}

private struct PlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        view.player?.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
