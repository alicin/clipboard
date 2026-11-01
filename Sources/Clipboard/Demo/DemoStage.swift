#if DEBUG
import AppKit
import ClipboardCore
import SwiftUI

struct PawBurst: Identifiable {
    struct Paw {
        let angle: CGFloat
        let distance: CGFloat
        let size: CGFloat
        let spin: Double
    }

    let id = UUID()
    let origin: CGPoint
    let paws: [Paw]
    var progress: CGFloat = 0
    var canvasOrigin = CGPoint.zero

    init(origin: CGPoint, count: Int = 12) {
        self.origin = origin
        paws = (0..<count).map { index in
            let i = CGFloat(index)
            return Paw(
                angle: i / CGFloat(count) * 2 * .pi + sin(i * 7.1) * 0.25,
                distance: 90 + 70 * abs(sin(i * 3.1)),
                size: 15 + 12 * abs(cos(i * 2.3)),
                spin: -50 + 100 * abs(sin(Double(index) * 5.7)))
        }
    }
}

@MainActor @Observable
final class DemoWorld {
    struct Caption: Equatable, Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }

    struct DocBlock: Identifiable {
        enum Kind {
            case title(String)
            case body(String)
            case rich(String)
            case link(String)
            case code(String)
            case image(NSImage)
            case color(ClipColor, String)
            case formField(label: String, value: String?)
        }

        let id = UUID()
        var kind: Kind
    }

    enum TitleCard { case intro, outro }

    struct DragGhost {
        let clip: Clip
        var point: CGPoint
    }

    var isDark = false
    var docBlocks: [DocBlock] = []
    var freshBlockID: UUID?
    var selectedBlockID: UUID?
    var statusFlash = false
    var caption: Caption?
    var keys: [String]?
    var keysToken = 0
    var titleCard: TitleCard?
    var titleRevealed = false
    var settingsVisible = false
    var consoleVisible = false
    var consoleText = ""
    var consoleResult = ""
    var consoleImage: NSImage?
    var dragGhost: DragGhost?
    var bursts: [PawBurst] = []
    var fadedOut = false

    var cursorVisible = false
    var cursorStagePoint = CGPoint(x: 800, y: 450)
    var cursorCanvasPoint = CGPoint.zero
    var cursorScale: CGFloat = 1
    var cursorPressed = false
    var ripplePoint: CGPoint?
    var rippleCanvasPoint = CGPoint.zero
    var rippleProgress: CGFloat = 0

    func syncCursor(camera: DemoCamera) {
        let projected = camera.project(cursorStagePoint)
        cursorCanvasPoint = CGPoint(x: projected.x / 2, y: projected.y / 2)
        cursorScale = pow(camera.zoom, 0.55)
        if let ripplePoint {
            let ripple = camera.project(ripplePoint)
            rippleCanvasPoint = CGPoint(x: ripple.x / 2, y: ripple.y / 2)
        }
        for index in bursts.indices {
            let origin = camera.project(bursts[index].origin)
            bursts[index].canvasOrigin = CGPoint(x: origin.x / 2, y: origin.y / 2)
        }
    }
}

enum DemoStageLayout {
    static let menuBarHeight: CGFloat = 30
    static let dockHeight: CGFloat = 66
    /// Where the bottom of the shelf sits, leaving room for the Dock under it.
    static let bottomGap: CGFloat = 86
    static var shelfY: CGFloat { DemoCamera.stage.height - bottomGap - Metrics.shelfHeight }
    static let documentFrame = CGRect(x: 330, y: 58, width: 940, height: 735)
    static let settingsFrame = CGRect(x: 400, y: 150, width: 800, height: 600)

    static func cardFrame(index: Int, scrollOffset: CGFloat) -> CGRect {
        CGRect(
            x: Metrics.shelfMargin + Metrics.stripInset + CGFloat(index) * (Metrics.cardWidth + Metrics.cardSpacing) - scrollOffset,
            y: shelfY + Metrics.barHeight + 12, width: Metrics.cardWidth, height: Metrics.cardHeight)
    }
}

struct DemoStage: View {
    let world: DemoWorld
    let model: PanelModel
    let stack: StackController
    let toast: ToastController
    let store: ClipStore
    let navigation: SettingsNavigation

    var body: some View {
        ZStack(alignment: .topLeading) {
            DemoWallpaper(isDark: world.isDark)
            DemoDocumentWindow(world: world)
                .frame(width: DemoStageLayout.documentFrame.width, height: DemoStageLayout.documentFrame.height)
                .offset(x: DemoStageLayout.documentFrame.minX, y: DemoStageLayout.documentFrame.minY)
            DemoMenuBar(world: world)
            DemoDock()
                .frame(width: DemoCamera.stage.width, height: DemoCamera.stage.height, alignment: .bottom)
                .padding(.bottom, 10)
            ShelfRoot(model: model)
                .frame(width: DemoCamera.stage.width, height: DemoCamera.stage.height)
            PreviewRoot(model: model, inset: 26)
                .frame(width: 812, height: 482)
                .offset(x: (DemoCamera.stage.width - 812) / 2, y: DemoStageLayout.shelfY - 12 + 26 - 482)
            StackRoot(stack: stack)
                .frame(width: 344, height: 560)
                .offset(x: DemoCamera.stage.width - 344 - 4, y: DemoStageLayout.menuBarHeight + 2)
            ToastView(state: toast.state)
                .frame(width: 520, height: 96)
                .offset(x: (DemoCamera.stage.width - 520) / 2, y: DemoCamera.stage.height - DemoStageLayout.bottomGap - 96)
            if world.consoleVisible {
                DemoConsole(world: world)
                    .offset(x: 330, y: 120)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            DemoSettingsWindow(store: store, navigation: navigation)
                .frame(width: DemoStageLayout.settingsFrame.width, height: DemoStageLayout.settingsFrame.height)
                .scaleEffect(world.settingsVisible ? 1 : 0.94)
                .opacity(world.settingsVisible ? 1 : 0)
                .offset(x: DemoStageLayout.settingsFrame.minX, y: DemoStageLayout.settingsFrame.minY)
            if let ghost = world.dragGhost {
                CardDragPreview(clip: ghost.clip, store: store, boards: model.pinboards)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                    .rotationEffect(.degrees(-3))
                    .position(ghost.point)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .frame(width: DemoCamera.stage.width, height: DemoCamera.stage.height, alignment: .topLeading)
        .clipped()
        .tint(Theme.accent)
        .environment(\.displayScale, DemoEngine.stageScale)
    }
}

struct DemoWallpaper: View {
    let isDark: Bool

    private func blob(_ color: Color, _ size: CGFloat, x: CGFloat, y: CGFloat, blur: CGFloat) -> some View {
        Circle().fill(color).frame(width: size, height: size).blur(radius: blur).position(x: x, y: y)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: isDark
                    ? [Color(red: 0.03, green: 0.13, blue: 0.18), Color(red: 0.03, green: 0.07, blue: 0.14)]
                    : [Color(red: 0.74, green: 0.96, blue: 0.93), Color(red: 0.70, green: 0.84, blue: 1.0)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            blob(Color(red: 0.07, green: 0.84, blue: 0.75).opacity(isDark ? 0.75 : 0.9), 720, x: 180, y: 760, blur: 90)
            blob(Color(red: 0.22, green: 0.55, blue: 1.0).opacity(isDark ? 0.7 : 0.75), 760, x: 1430, y: 690, blur: 100)
            blob(Color(red: 0.55, green: 0.48, blue: 1.0).opacity(isDark ? 0.55 : 0.5), 520, x: 860, y: 860, blur: 90)
            blob(Color(red: 1.0, green: 0.52, blue: 0.56).opacity(isDark ? 0.4 : 0.45), 300, x: 560, y: 640, blur: 70)
            blob(Color(red: 0.40, green: 0.95, blue: 0.86).opacity(isDark ? 0.3 : 0.5), 460, x: 1320, y: 120, blur: 110)
        }
        .frame(width: DemoCamera.stage.width, height: DemoCamera.stage.height)
        .animation(.easeInOut(duration: 0.5), value: isDark)
    }
}

/// What sits behind the whole recording, outside the rounded frame.
struct DemoCanvasBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.14, blue: 0.17), Color(red: 0.03, green: 0.06, blue: 0.13)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 0.07, green: 0.84, blue: 0.75).opacity(0.5)).frame(width: 760).blur(radius: 130).position(x: 120, y: 90)
            Circle().fill(Color(red: 0.22, green: 0.50, blue: 1.0).opacity(0.5)).frame(width: 820).blur(radius: 150).position(x: 1200, y: 660)
            Circle().fill(Color(red: 0.55, green: 0.48, blue: 1.0).opacity(0.28)).frame(width: 520).blur(radius: 120).position(x: 1160, y: 60)
            ForEach(0..<54, id: \.self) { index in
                let i = CGFloat(index)
                let row = index / 9
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 26 + 10 * abs(sin(i * 3.7))))
                    .foregroundStyle(.white.opacity(0.05))
                    .rotationEffect(.degrees(Double(index) * 47))
                    .position(
                        x: 60 + CGFloat(index % 9) * 146 + sin(i * 12.9) * 32 + (row.isMultiple(of: 2) ? 0 : 66),
                        y: 58 + CGFloat(row) * 120 + cos(i * 7.3) * 24)
            }
        }
    }
}

private struct DemoMenuBar: View {
    let world: DemoWorld

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 13, weight: .medium))
            Text("Notes").font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "Format", "View", "Window", "Help"], id: \.self) { item in
                Text(item).font(.system(size: 13))
            }
            Spacer()
            ZStack {
                Image(nsImage: StatusGlyph.make())
                    .renderingMode(.template)
                    .scaleEffect(world.statusFlash ? 0.4 : 1)
                    .opacity(world.statusFlash ? 0 : 1)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .scaleEffect(world.statusFlash ? 1.15 : 0.4)
                    .opacity(world.statusFlash ? 1 : 0)
            }
            .frame(width: 20, height: 20)
            Image(systemName: "wifi").font(.system(size: 13, weight: .medium))
            Image(systemName: "battery.75percent").font(.system(size: 15))
            Text("Sat 9:41 AM").font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(world.isDark ? Color.white : Color.black.opacity(0.85))
        .padding(.horizontal, 16)
        .frame(width: DemoCamera.stage.width, height: DemoStageLayout.menuBarHeight)
        .background(.white.opacity(world.isDark ? 0.06 : 0.28))
    }
}

private struct DemoDock: View {
    private static let apps = [
        "com.apple.finder", "com.apple.Safari", "com.apple.Notes", "com.apple.mail", "com.apple.MobileSMS", "com.apple.Photos",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.tinyspeck.slackmacgap",
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.apps, id: \.self) { bundleID in
                if let icon = AppAppearance.shared.style(for: bundleID).icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 50, height: 50)
                }
            }
            Rectangle().fill(.primary.opacity(0.18)).frame(width: 1, height: 40).padding(.horizontal, 2)
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 50, height: 50)
        }
        .padding(.horizontal, 12)
        .frame(height: DemoStageLayout.dockHeight)
        .glassSurface(cornerRadius: 22)
    }
}

private struct DemoTrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
            Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18))
            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
        }
        .frame(width: 52, height: 12)
    }
}

private struct DemoDocumentWindow: View {
    let world: DemoWorld

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Mochi's first week").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                HStack {
                    DemoTrafficLights()
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 40)
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(world.docBlocks) { block in
                    DemoDocBlockView(block: block, isFresh: world.freshBlockID == block.id, isSelected: world.selectedBlockID == block.id)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 44)
            .padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.cardPaper, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.28), radius: 26, y: 14)
    }
}

private struct DemoDocBlockView: View {
    let block: DemoWorld.DocBlock
    let isFresh: Bool
    let isSelected: Bool

    var body: some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.32) : (isFresh ? Theme.accent.opacity(0.24) : .clear))
            )
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .title(let text):
            Text(text).font(.system(size: 30, weight: .bold))
        case .body(let text):
            Text(text).font(.system(size: 16)).lineSpacing(3)
        case .rich(let text):
            Text(text).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.accentDeep)
        case .link(let text):
            Text(text).font(.system(size: 16)).foregroundStyle(Theme.accentDeep).underline()
        case .code(let text):
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color(white: 0.92))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        case .color(let color, let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.swiftUIColor).frame(width: 34, height: 34)
                Text(text).font(.system(size: 16, design: .monospaced))
            }
        case .formField(let label, let value):
            HStack(spacing: 12) {
                Text(label).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                Text(value ?? " ")
                    .font(.system(size: 15))
                    .padding(.horizontal, 12)
                    .frame(width: 340, height: 36, alignment: .leading)
                    .background(Theme.cardTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(value == nil ? Color.primary.opacity(0.1) : Theme.accent, lineWidth: value == nil ? 0.5 : 1.5)
                    }
            }
        }
    }
}

private struct DemoSettingsWindow: View {
    let store: ClipStore
    let navigation: SettingsNavigation

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    var body: some View {
        SettingsRoot(store: store, navigation: navigation)
            .clipShape(shape)
            .overlay(alignment: .topLeading) {
                DemoTrafficLights().padding(.leading, 21).padding(.top, 21)
            }
            .overlay { shape.strokeBorder(.primary.opacity(0.14), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.35), radius: 34, y: 18)
    }
}

private struct DemoConsole: View {
    let world: DemoWorld

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                DemoTrafficLights()
                Spacer()
                Text("Terminal").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Color.clear.frame(width: 52, height: 12)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(world.consoleText)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(Theme.accentTop)
                    Text(world.consoleResult)
                        .font(.system(size: 13.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(3)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                if let image = world.consoleImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(height: 350)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 940, height: 430)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
    }
}

/// A stand-in for the AppKit field, which can't show a caret without a key window.
struct DemoTextField: View {
    let text: String
    let placeholder: String

    private var caret: some View {
        Rectangle()
            .fill(Theme.accentDeep)
            .frame(width: 1.5, height: 17)
            .phaseAnimator([1.0, 1.0, 0.0, 0.0]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in
                .linear(duration: 0.26)
            }
    }

    var body: some View {
        HStack(spacing: 1) {
            if text.isEmpty {
                caret
                Text(placeholder).foregroundStyle(.secondary)
            } else {
                Text(text)
                caret
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13.5))
        .lineLimit(1)
    }
}

// MARK: - Overlay

struct DemoOverlay: View {
    let world: DemoWorld

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let caption = world.caption {
                DemoCaptionCard(caption: caption)
                    .padding(.leading, 26)
                    .padding(.top, 24)
                    .id(caption.id)
                    .transition(.asymmetric(
                        insertion: .offset(x: -26).combined(with: .opacity),
                        removal: .offset(x: 12).combined(with: .opacity)))
            }
            if let keys = world.keys {
                DemoKeyHUD(keys: keys)
                    .id(world.keysToken)
                    .frame(width: DemoEngine.overlaySize.width, height: DemoEngine.overlaySize.height, alignment: .bottom)
                    .padding(.bottom, 30)
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
            }
            ForEach(world.bursts) { burst in
                DemoPawBurstView(burst: burst)
            }
            if world.ripplePoint != nil {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 26 * world.cursorScale))
                    .foregroundStyle(Theme.ringGradient)
                    .shadow(color: .white.opacity(0.7), radius: 2)
                    .scaleEffect(0.5 + 0.95 * world.rippleProgress)
                    .opacity(Double(1 - world.rippleProgress))
                    .position(world.rippleCanvasPoint)
            }
            if world.cursorVisible {
                DemoCursor()
                    .scaleEffect(world.cursorScale * (world.cursorPressed ? 0.84 : 1), anchor: .topLeading)
                    .position(x: world.cursorCanvasPoint.x + 16, y: world.cursorCanvasPoint.y + 16)
                    .transition(.opacity)
            }
            if let card = world.titleCard {
                DemoTitleCardView(world: world, kind: card)
                    .transition(.opacity)
            }
            if world.fadedOut {
                Color.black.transition(.opacity)
            }
        }
        .frame(width: DemoEngine.overlaySize.width, height: DemoEngine.overlaySize.height)
        .environment(\.displayScale, 2)
    }
}

private struct DemoPawBurstView: View {
    let burst: PawBurst

    var body: some View {
        let t = burst.progress
        let eased = 1 - pow(1 - t, 3)
        ForEach(burst.paws.indices, id: \.self) { index in
            let paw = burst.paws[index]
            Image(systemName: "pawprint.fill")
                .font(.system(size: paw.size))
                .foregroundStyle(Theme.ringGradient)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .rotationEffect(.degrees(paw.spin * Double(t)))
                .opacity(Double(min(1, (1 - t) * 1.7)))
                .position(
                    x: burst.canvasOrigin.x + cos(paw.angle) * paw.distance * eased,
                    y: burst.canvasOrigin.y + sin(paw.angle) * paw.distance * eased + 40 * t * t)
        }
    }
}

private struct DemoCaptionCard: View {
    let caption: DemoWorld.Caption

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 25))
                .foregroundStyle(Theme.ringGradient)
                .rotationEffect(.degrees(-12))
            VStack(alignment: .leading, spacing: 4) {
                Text(caption.title).font(.system(size: 25, weight: .bold)).foregroundStyle(.white)
                Text(caption.detail).font(.system(size: 14.5, weight: .medium)).foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color(red: 0.03, green: 0.09, blue: 0.11), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.75) }
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}

private struct DemoKeyHUD: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.onAccent)
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(.horizontal, key.count > 1 ? 10 : 0)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(.white)
                            .shadow(color: Theme.accent.opacity(0.9), radius: 0, y: 3)
                    }
            }
        }
        .padding(12)
        .background(Color(red: 0.03, green: 0.09, blue: 0.11).opacity(0.88), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.75) }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }
}

/// The classic macOS pointer, drawn large and crisp at any camera zoom.
private struct DemoCursor: View {
    private var arrow: Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 21))
        path.addLine(to: CGPoint(x: 5, y: 16.2))
        path.addLine(to: CGPoint(x: 8.6, y: 24.6))
        path.addLine(to: CGPoint(x: 12, y: 23.2))
        path.addLine(to: CGPoint(x: 8.4, y: 15))
        path.addLine(to: CGPoint(x: 15, y: 15))
        path.closeSubpath()
        return path
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            arrow.stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            arrow.fill(.black)
        }
        .frame(width: 32, height: 32, alignment: .topLeading)
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }
}

private struct DemoTitleCardView: View {
    let world: DemoWorld
    let kind: DemoWorld.TitleCard

    private var isRevealed: Bool { world.titleRevealed }

    var body: some View {
        ZStack {
            DemoCanvasBackground()
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 190, height: 190)
                    .scaleEffect(isRevealed ? 1 : 0.55)
                    .rotationEffect(.degrees(isRevealed ? 0 : -14))
                    .opacity(isRevealed ? 1 : 0)
                Text("Clipboard")
                    .font(.system(size: 66, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .offset(y: isRevealed ? 0 : 22)
                    .opacity(isRevealed ? 1 : 0)
                    .animation(Motion.bouncy.delay(0.1), value: isRevealed)
                Text(kind == .intro ? "Everything you copy, one keystroke away." : "Press it once and you won't go back.")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .offset(y: isRevealed ? 0 : 18)
                    .opacity(isRevealed ? 1 : 0)
                    .animation(Motion.bouncy.delay(0.2), value: isRevealed)
                if kind == .outro {
                    HStack(spacing: 8) {
                        ForEach(["⇧", "⌘", "V"], id: \.self) { key in
                            Text(key)
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.onAccent)
                                .frame(width: 50, height: 50)
                                .background {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(.white)
                                        .shadow(color: Theme.accent, radius: 0, y: 3)
                                }
                        }
                    }
                    .padding(.top, 10)
                    .scaleEffect(isRevealed ? 1 : 0.7)
                    .opacity(isRevealed ? 1 : 0)
                    .animation(Motion.bouncy.delay(0.32), value: isRevealed)
                    Text("Kittens sold separately.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 6)
                        .opacity(isRevealed ? 1 : 0)
                        .animation(.easeOut(duration: 0.4).delay(1.1), value: isRevealed)
                }
            }
            .animation(Motion.bouncy, value: isRevealed)
        }
        .frame(width: DemoEngine.overlaySize.width, height: DemoEngine.overlaySize.height)
    }
}
#endif
