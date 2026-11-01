import AppKit
import ClipboardCore
import SwiftUI
import UniformTypeIdentifiers

enum ClipDrag {
    @MainActor static var currentClipID: Int64?
}

/// Drawn behind the whole row, so it can't wash over the neighboring cards. Every card is the same width, so its position
/// comes straight from the index.
private struct SelectionGlow: View {
    let index: Int
    @State private var isLit = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
    }

    var body: some View {
        shape
            .fill(Theme.accentTop)
            .shadow(color: Theme.accentTop, radius: 4)
            .shadow(color: Theme.accent.opacity(0.8), radius: 10)
            .shadow(color: Theme.accent.opacity(0.45), radius: 18)
            // Hollow, so it can't show through a card that's fading in or out above it.
            .overlay { shape.inset(by: 1).blendMode(.destinationOut) }
            .compositingGroup()
            .frame(width: Metrics.cardWidth, height: Metrics.cardHeight)
            .scaleEffect(ClipCard.selectedScale)
            .offset(x: CGFloat(index) * (Metrics.cardWidth + Metrics.cardSpacing))
            .opacity(isLit ? 0.7 : 0)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.3).delay(0.1)) { isLit = true } }
    }
}

struct CardStrip: View {
    @Bindable var model: PanelModel

    private var selectedIndex: Int? {
        model.clips.firstIndex { $0.id == model.selectedID }
    }

    // A mask also clips. This one reaches up behind the top bar for a card's glow, and fades out at the bottom, where
    // the glass would otherwise cut the glow off in a hard line.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 14)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 14)
        }
        .mask {
            VStack(spacing: 0) {
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 21)
            }
        }
        .padding(.top, -Metrics.barHeight)
    }

    private var cards: some View {
        LazyHStack(spacing: Metrics.cardSpacing) {
            ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                ClipCard(
                    clip: clip, index: index, model: model, isSelected: clip.id == model.selectedID,
                    shortcutNumber: model.shortcutNumber(forIndex: index)
                )
                .id(clip.id)
                .zIndex(clip.id == model.selectedID ? 1 : 0)
                .onAppear { model.cardAppeared(at: index) }
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.85).combined(with: .opacity),
                        removal: .scale(scale: 0.6).combined(with: .opacity)))
            }
        }
        .scrollTargetLayout()
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if let selectedIndex, model.flyingClipID == nil {
                    // A new identity per card, so one glow fades out as the next fades in instead of sliding across.
                    SelectionGlow(index: selectedIndex)
                        .id(selectedIndex)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: selectedIndex)
        }
        .padding(.top, 12)
        .padding(.bottom, 30)
    }

    var body: some View {
        #if DEBUG
        if AppEnvironment.isDemo {
            demoStrip
        } else {
            scrollingStrip
        }
        #else
        scrollingStrip
        #endif
    }

    #if DEBUG
    // Programmatic scrolling needs a window, and the demo renders without one.
    private var demoStrip: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                cards
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, Metrics.stripInset)
                    .offset(x: -model.demoStripOffset)
            }
            .mask(edgeFade)
            .id(model.listIdentity)
    }
    #endif

    private var scrollingStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                cards
            }
            .contentMargins(.horizontal, Metrics.stripInset, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
            .scrollClipDisabled()
            .mask(edgeFade)
            .id(model.listIdentity)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x + $0.contentInsets.leading } action: { _, offset in
                model.updateFirstVisible(contentOffset: offset)
            }
            .onChange(of: model.selectedID) { _, selected in
                // While the list is being rebuilt the row is already at its start, with nothing to scroll to yet.
                guard let selected, !model.isRevealing else { return }
                withAnimation(Motion.snappy) { proxy.scrollTo(selected) }
            }
            .onChange(of: model.scrollResetToken) {
                guard let first = model.clips.first?.id else { return }
                DispatchQueue.main.async {
                    withAnimation(Motion.snappy) { proxy.scrollTo(first, anchor: .leading) }
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder func cardTilt(x: Double, y: Double) -> some View {
        #if DEBUG
        if AppEnvironment.isDemo {
            // Drawn large and shrunk back, because a tilted view flattens at 1x without a window.
            scaleEffect(3)
                .rotation3DEffect(.degrees(x), axis: (1, 0, 0), perspective: 0.5 / 3)
                .rotation3DEffect(.degrees(y), axis: (0, 1, 0), perspective: 0.5 / 3)
                .scaleEffect(1 / 3)
        } else {
            rotation3DEffect(.degrees(x), axis: (1, 0, 0), perspective: 0.5)
                .rotation3DEffect(.degrees(y), axis: (0, 1, 0), perspective: 0.5)
        }
        #else
        rotation3DEffect(.degrees(x), axis: (1, 0, 0), perspective: 0.5)
            .rotation3DEffect(.degrees(y), axis: (0, 1, 0), perspective: 0.5)
        #endif
    }
}

struct ClipCard: View {
    // Whole-point sizes: an edge on a fraction of a pixel draws a stray line of the card's color past its rounded corners.
    static let selectedScale = CGSize(width: 244 / Metrics.cardWidth, height: 268 / Metrics.cardHeight)
    private static let hoverScale = CGSize(width: 230 / Metrics.cardWidth, height: 252 / Metrics.cardHeight)

    let clip: Clip
    let index: Int
    let model: PanelModel
    let isSelected: Bool
    let shortcutNumber: Int?

    @State private var hoverPoint: CGPoint?
    @State private var hasAppeared: Bool

    init(clip: Clip, index: Int, model: PanelModel, isSelected: Bool, shortcutNumber: Int?) {
        self.clip = clip
        self.index = index
        self.model = model
        self.isSelected = isSelected
        self.shortcutNumber = shortcutNumber
        _hasAppeared = State(initialValue: !model.isRevealing)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
    }

    private var effectiveHover: CGPoint? {
        #if DEBUG
        if AppEnvironment.isUITest {
            return DemoControl.shared.hover?.clipID == clip.id ? DemoControl.shared.hover?.point : nil
        }
        #endif
        return hoverPoint
    }

    private var isHovering: Bool { effectiveHover != nil }
    private var isFlying: Bool { model.flyingClipID == clip.id }

    private var tilt: (x: Double, y: Double) {
        // The glow behind a selected card stays still, so a tilting card would pull away from it and expose its inner edge.
        guard let hoverPoint = effectiveHover, !isSelected, !Motion.isReduced else { return (0, 0) }
        let x = (hoverPoint.x / Metrics.cardWidth - 0.5) * 2
        let y = (hoverPoint.y / Metrics.cardHeight - 0.5) * 2
        return (Double(-y) * 3.5, Double(x) * 3.5)
    }

    var body: some View {
        face
            .frame(width: Metrics.cardWidth, height: Metrics.cardHeight)
            .background(Theme.cardPaper)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
            .overlay { shine }
            // Centered on the edge, to cover the soft pixels where the paper would otherwise show around the outside.
            .overlay { shape.stroke(Theme.accent, lineWidth: 1.5).opacity(isSelected ? 1 : 0) }
            .overlay(alignment: .bottomTrailing) { hoverActions }
            .contentShape(.dragPreview, shape)
            .contentShape(shape)
            .onTapGesture(count: 2) { model.actions.paste(clip, false) }
            .simultaneousGesture(TapGesture().onEnded { model.select(clip) })
            .onDrag {
                ClipDrag.currentClipID = clip.id
                return ClipDragProvider.make(for: clip, store: model.store)
            } preview: {
                CardDragPreview(clip: clip, store: model.store, boards: model.pinboards)
            }
            .contextMenu { ClipMenu(clip: clip, model: model) }
            .cardTilt(x: tilt.x, y: tilt.y)
            .onContinuousHover(coordinateSpace: .local) { phase in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    switch phase {
                    case .active(let point): hoverPoint = point
                    case .ended: hoverPoint = nil
                    }
                }
            }
            .scaleEffect(isSelected ? Self.selectedScale : (isHovering ? Self.hoverScale : CGSize(width: 1, height: 1)))
            .shadow(color: .black.opacity(isSelected ? 0 : 0.15), radius: 7, y: 3)
            .animation(Motion.bouncy, value: isSelected)
            .scaleEffect(isFlying ? 1.07 : (hasAppeared ? 1 : 0.92))
            .offset(y: isFlying ? -60 : (hasAppeared ? 0 : 34))
            .opacity(isFlying ? 0 : (hasAppeared ? 1 : 0))
            .onAppear { revealIfNeeded() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.actions.paste(clip, false) }
    }

    private var face: some View {
        CardFace(
            clip: clip, store: model.store, query: model.query, boards: model.pinboards,
            shortcutNumber: shortcutNumber, hidesPinDots: isHovering)
    }

    /// A soft highlight that follows the pointer, like light catching a raised card.
    @ViewBuilder private var shine: some View {
        if let hoverPoint = effectiveHover, !Motion.isReduced {
            RadialGradient(
                colors: [.white.opacity(0.22), .clear], center: UnitPoint(
                    x: hoverPoint.x / Metrics.cardWidth, y: hoverPoint.y / Metrics.cardHeight),
                startRadius: 0, endRadius: 170
            )
            .blendMode(.plusLighter)
            .clipShape(shape)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder private var hoverActions: some View {
        if isHovering, shortcutNumber == nil {
            HStack(spacing: 0) {
                pinMenu
                actionButton("doc.on.doc", label: "Copy") { model.actions.copy(clip) }
                actionButton("trash", label: "Delete") { model.delete(clip) }
            }
            .padding(2)
            // Not a material: one nested inside the shelf's glass thins the glass's blur for as long as it's on screen.
            .background(Theme.cardPaper, in: Capsule())
            .overlay { Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
            .padding(5)
            .transition(.scale(scale: 0.8, anchor: .bottomTrailing).combined(with: .opacity))
        }
    }

    private var pinMenu: some View {
        Menu {
            PinMenuItems(clip: clip, model: model)
        } label: {
            Image(systemName: clip.pinboardIDs.isEmpty ? "pin" : "pin.fill")
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 26, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pin to a pinboard")
        .accessibilityLabel("Pin")
    }

    private func actionButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 22)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func revealIfNeeded() {
        guard !hasAppeared else { return }
        let position = min(max(index - model.firstVisibleIndex, 0), 10)
        withAnimation(Motion.bouncy.delay(0.05 + Double(position) * 0.03)) { hasAppeared = true }
    }

    private var accessibilityDescription: String {
        var parts = [clip.title ?? clip.kind.displayName]
        if let source = clip.source.name { parts.append("from \(source)") }
        parts.append(ClipFormat.relativeTime(clip.sortedAt))
        if let preview = clip.preview { parts.append(String(preview.prefix(200))) }
        return parts.joined(separator: ", ")
    }
}

/// A clean copy of the card for the drag image, with no glow or shadow to bleed past its rounded corners.
struct CardDragPreview: View {
    let clip: Clip
    let store: ClipStore
    let boards: [Pinboard]

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
    }

    var body: some View {
        CardFace(clip: clip, store: store, query: "", boards: boards, shortcutNumber: nil, hidesPinDots: false)
            .frame(width: Metrics.cardWidth, height: Metrics.cardHeight)
            .background(Theme.cardPaper)
            .clipShape(shape)
            .scaleEffect(0.72)
            .frame(width: Metrics.cardWidth * 0.72, height: Metrics.cardHeight * 0.72)
            .contentShape(.dragPreview, RoundedRectangle(cornerRadius: Metrics.cardRadius * 0.72, style: .continuous))
    }
}

#if DEBUG
@MainActor
func renderDragPreview(of clip: Clip, store: ClipStore, boards: [Pinboard], to path: String) {
    let renderer = ImageRenderer(content: CardDragPreview(clip: clip, store: store, boards: boards))
    renderer.scale = 2
    guard let image = renderer.cgImage else { return }
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
#endif

private struct CardFace: View {
    let clip: Clip
    let store: ClipStore
    let query: String
    let boards: [Pinboard]
    let shortcutNumber: Int?
    let hidesPinDots: Bool

    var body: some View {
        let style = AppAppearance.shared.style(for: clip.source.bundleID)
        VStack(spacing: 0) {
            CardHeader(clip: clip, style: style)
            CardContent(clip: clip, store: store, query: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            CardFooter(clip: clip, boards: boards, shortcutNumber: shortcutNumber, hidesPinDots: hidesPinDots)
        }
    }
}

private struct CardHeader: View {
    let clip: Clip
    let style: AppAppearance.Style

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.title ?? clip.kind.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text(ClipFormat.relativeTime(clip.sortedAt))
                    .font(.system(size: 11, weight: .medium))
                    .opacity(0.78)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let icon = style.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    .help(clip.source.name ?? "")
            }
        }
        .foregroundStyle(style.foreground)
        .padding(.leading, 13)
        .padding(.trailing, 9)
        .frame(height: 50)
        .background {
            LinearGradient(colors: [style.colorTop, style.color], startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.28)).frame(height: 0.5)
        }
    }
}

private struct CardFooter: View {
    let clip: Clip
    let boards: [Pinboard]
    let shortcutNumber: Int?
    let hidesPinDots: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(ClipFormat.footer(for: clip))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if !hidesPinDots {
                ForEach(boards.filter { clip.pinboardIDs.contains($0.id) }) { board in
                    Circle()
                        .fill(PinboardPalette.color(board.color))
                        .frame(width: 8, height: 8)
                        .help(board.name)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 7)
                    .frame(height: 19)
                    .background(Theme.accentGradient, in: Capsule())
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 30)
        .animation(Motion.bouncy, value: shortcutNumber)
        .animation(Motion.snappy, value: hidesPinDots)
    }
}

private struct CardContent: View {
    let clip: Clip
    let store: ClipStore
    let query: String

    var body: some View {
        switch clip.kind {
        case .text: TextContent(clip: clip, query: query)
        case .code: CodeContent(clip: clip, query: query)
        case .link: LinkContent(clip: clip, store: store, query: query)
        case .image: ImageContent(clip: clip, store: store)
        case .file: FileContent(clip: clip)
        case .color: ColorContent(clip: clip)
        }
    }
}

private struct FadedBottom: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content.mask {
            LinearGradient(
                stops: [.init(color: .black, location: isActive ? 0.78 : 1), .init(color: isActive ? .clear : .black, location: 1)],
                startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct TextContent: View {
    let clip: Clip
    let query: String

    private var attributed: AttributedString {
        var text = AttributedString(SearchHighlighter.excerpt(of: clip.preview ?? "", query: query))
        SearchHighlighter.apply(to: &text, query: query)
        return text
    }

    var body: some View {
        if clip.preview != nil {
            Text(attributed)
                .font(.system(size: 12.5))
                .lineSpacing(1.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 13)
                .padding(.top, 11)
                .modifier(FadedBottom(isActive: clip.textLength > 170))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "shippingbox").font(.system(size: 24, weight: .light))
                Text("Content from \(clip.source.name ?? "another app")")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .padding(14)
        }
    }
}

/// Always dark, in both appearances, so code reads as code at a glance along the row.
private struct CodeContent: View {
    let clip: Clip
    let query: String

    private var attributed: AttributedString {
        var text = CodeStyler.styled(clip)
        SearchHighlighter.apply(to: &text, query: query)
        return text
    }

    var body: some View {
        Text(attributed)
            .font(.system(size: 10.5, design: .monospaced))
            .lineSpacing(2.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 13)
            .padding(.top, 11)
            .modifier(FadedBottom(isActive: clip.textLength > 170))
            .background(Theme.codeBackground)
    }
}

private struct LinkContent: View {
    let clip: Clip
    let store: ClipStore
    let query: String
    @State private var image: NSImage?

    init(clip: Clip, store: ClipStore, query: String) {
        self.clip = clip
        self.store = store
        self.query = query
        _image = State(initialValue: ThumbnailCache.shared.cached(clip.uuid))
    }

    private var host: String { ClipFormat.displayHost(of: clip) }

    private func highlighted(_ string: String) -> AttributedString {
        var text = AttributedString(string)
        SearchHighlighter.apply(to: &text, query: query)
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 92)
                    .clipped()
            } else {
                LetterTile(text: host)
                    .padding(.horizontal, 13)
                    .padding(.top, 13)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(highlighted(clip.linkTitle ?? host))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(image == nil ? 3 : 2)
                Text(highlighted(clip.preview ?? ""))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.accentDeep)
                    .lineLimit(image == nil ? 4 : 2)
            }
            .padding(.horizontal, 13)
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: clip.uuid + (clip.hasThumbnail ? "1" : "0")) {
            image = await ThumbnailCache.shared.thumbnail(for: clip, store: store)
        }
    }
}

/// Stands in for a favicon, since fetching a real one would contact the site just because a link was copied.
private struct LetterTile: View {
    let text: String

    private var hue: Double {
        let sum = text.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Double(sum % 360) / 360
    }

    var body: some View {
        Text(String(text.prefix(1)).uppercased())
            .font(.system(size: 21, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(
                LinearGradient(
                    colors: [Color(hue: hue, saturation: 0.55, brightness: 0.95), Color(hue: hue, saturation: 0.72, brightness: 0.78)],
                    startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
    }
}

private struct ImageContent: View {
    let clip: Clip
    let store: ClipStore
    @State private var image: NSImage?

    init(clip: Clip, store: ClipStore) {
        self.clip = clip
        self.store = store
        _image = State(initialValue: ThumbnailCache.shared.cached(clip.uuid))
    }

    var body: some View {
        // Overlays, because a filling image would otherwise grow the card past its header and footer.
        Rectangle()
            .fill(Theme.cardTint)
            .overlay {
                if let image {
                    // The same picture, blurred, fills the letterbox instead of a flat bar.
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 18)
                        .opacity(0.55)
                }
            }
            .clipped()
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                        .padding(8)
                }
            }
        .task(id: clip.uuid) {
            image = await ThumbnailCache.shared.thumbnail(for: clip, store: store)
        }
    }
}

private struct FileContent: View {
    let clip: Clip
    @State private var thumbnail: NSImage?

    private var paths: [String] { clip.preview?.split(separator: "\n").map(String.init) ?? [] }
    private var firstPath: String { paths.first ?? "" }
    private var isMissing: Bool { !FileManager.default.fileExists(atPath: firstPath) }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            ZStack {
                if clip.itemCount > 1 {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: paths.count > 1 ? paths[1] : firstPath))
                        .resizable().scaledToFit().frame(width: 72, height: 72)
                        .rotationEffect(.degrees(9)).offset(x: 16)
                }
                Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: firstPath))
                    .resizable().scaledToFit().frame(maxWidth: thumbnail == nil ? 84 : 190, maxHeight: thumbnail == nil ? 84 : 108)
                    .overlay {
                        if thumbnail != nil { Rectangle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5) }
                    }
                    .shadow(color: .black.opacity(thumbnail == nil ? 0 : 0.18), radius: 3, y: 1)
                    .rotationEffect(.degrees(clip.itemCount > 1 ? -5 : 0))
            }
            .frame(height: 108)
            .opacity(isMissing ? 0.4 : 1)
            Text((firstPath as NSString).lastPathComponent)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            if isMissing {
                Text("File moved or deleted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .task(id: firstPath) {
            guard clip.itemCount == 1, !isMissing else { return }
            thumbnail = await ThumbnailCache.shared.fileThumbnail(path: firstPath)
        }
    }
}

private struct ColorContent: View {
    let clip: Clip

    var body: some View {
        let color = clip.preview.flatMap(ClipColor.parse)
        ZStack {
            CheckerBackground()
            Rectangle().fill(color?.swiftUIColor ?? .gray)
            Text(clip.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(color?.readableForeground ?? .white)
                .multilineTextAlignment(.center)
                .padding(12)
        }
    }
}

/// Shows through only for translucent colors, the one case where the difference matters.
private struct CheckerBackground: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 8
            for row in 0...Int(size.height / side) {
                for column in 0...Int(size.width / side) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)
                    context.fill(Path(rect), with: .color(.gray.opacity(0.3)))
                }
            }
        }
    }
}

private struct PinMenuItems: View {
    let clip: Clip
    let model: PanelModel

    var body: some View {
        ForEach(model.pinboards) { board in
            Toggle(board.name, isOn: Binding(
                get: { clip.pinboardIDs.contains(board.id) },
                set: { _ in model.togglePin(clip, board: board) }))
        }
        if !model.pinboards.isEmpty { Divider() }
        Button("New pinboard…") { model.beginNewPinboard(pinning: clip) }
    }
}

private struct ClipMenu: View {
    let clip: Clip
    let model: PanelModel

    var body: some View {
        Button("Paste") { model.actions.paste(clip, false) }
        Button(Preferences.shared.plainTextByDefault ? "Paste with formatting" : "Paste as plain text") {
            model.actions.paste(clip, true)
        }
        Button("Copy") { model.actions.copy(clip) }
        Button("Add to Paste Stack") { model.actions.addToStack(clip) }
        Divider()
        Menu("Pin to") { PinMenuItems(clip: clip, model: model) }
        Button("Rename…") { model.beginRename(clip) }
        if clip.kind == .link, let url = clip.preview.flatMap(ClipClassifier.linkURL(from:)) {
            Button("Open link") {
                NSWorkspace.shared.open(url)
                model.actions.close()
            }
        }
        if clip.kind == .file, let path = clip.preview?.split(separator: "\n").first.map(String.init) {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                model.actions.close()
            }
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete(clip) }
    }
}

enum ClipDragProvider {
    @MainActor static func make(for clip: Clip, store: ClipStore) -> NSItemProvider {
        switch clip.kind {
        case .file:
            if let path = clip.preview?.split(separator: "\n").first.map(String.init) {
                return NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider()
            }
        case .image:
            if let payload = try? store.payload(for: clip),
                let image = payload.joined().first(where: { UTType($0.uti)?.conforms(to: .image) == true }) {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: image.uti, visibility: .all) { completion in
                    completion(image.data, nil)
                    return nil
                }
                return provider
            }
        case .link:
            if let url = clip.preview.flatMap(ClipClassifier.linkURL(from:)) {
                return NSItemProvider(object: url as NSURL)
            }
        case .text, .code, .color:
            break
        }
        let text = (try? store.fullText(clipID: clip.id)) ?? clip.preview ?? ""
        return NSItemProvider(object: text as NSString)
    }
}
