#if DEBUG
import AppKit
import ClipboardCore
import SwiftUI

/// The video itself: every scene, caption, key press and camera move, on one timeline.
@MainActor
final class DemoScript {
    private let engine: DemoEngine
    private let world: DemoWorld
    private let model: PanelModel
    private let stack: StackController
    private let toast: ToastController
    private let store: ClipStore
    private let writer: PasteboardWriter
    private let navigation: SettingsNavigation
    private let onlySections: Set<String>?
    private let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
    private var keysClearFrame: Int?
    private var frameCounter = 0
    private var ripple: (start: Int, length: Int)?
    private var flashClearFrame: Int?
    private var trackedClip: (id: Int64, zoom: CGFloat)?
    private var stripIdentity = -1

    init(
        engine: DemoEngine, world: DemoWorld, model: PanelModel, stack: StackController, toast: ToastController, store: ClipStore,
        writer: PasteboardWriter, navigation: SettingsNavigation, onlySections: Set<String>?
    ) {
        self.engine = engine
        self.world = world
        self.model = model
        self.stack = stack
        self.toast = toast
        self.store = store
        self.writer = writer
        self.navigation = navigation
        self.onlySections = onlySections
        engine.onFrame = { [weak self] in self?.perFrame() }
    }

    private func perFrame() {
        frameCounter += 1
        if let clear = keysClearFrame, frameCounter >= clear {
            keysClearFrame = nil
            withAnimation(.easeIn(duration: 0.14)) { world.keys = nil }
        }
        if let clear = flashClearFrame, frameCounter >= clear {
            flashClearFrame = nil
            withAnimation(Motion.bouncy) { world.statusFlash = false }
        }
        if let ripple {
            let progress = CGFloat(frameCounter - ripple.start) / CGFloat(ripple.length)
            if progress >= 1 {
                self.ripple = nil
                world.ripplePoint = nil
            } else {
                world.rippleProgress = progress
            }
        }
        if !world.bursts.isEmpty {
            for index in world.bursts.indices { world.bursts[index].progress += CGFloat(1 / (1.0 * DemoEngine.fps)) }
            world.bursts.removeAll { $0.progress >= 1 }
        }
        driveStrip()
        if let tracked = trackedClip, let index = model.clips.firstIndex(where: { $0.id == tracked.id }) {
            let frame = cardFrame(index)
            // Sits a little low in the frame, which leaves the caption's corner clear.
            engine.camera.targetCenter = CGPoint(x: frame.midX, y: frame.midY - 42)
            engine.camera.targetZoom = tracked.zoom
        }
    }

    // MARK: Helpers

    private func wait(_ seconds: Double) async {
        await engine.wait(seconds)
    }

    private func section(_ name: String, _ body: () async -> Void) async {
        engine.isFastForwarding = onlySections.map { !$0.contains(name) } ?? false
        await body()
    }

    private func caption(_ title: String, _ detail: String) {
        print("demo: caption \(engine.writtenFrames) \(title)")
        withAnimation(Motion.bouncy) { world.caption = DemoWorld.Caption(title: title, detail: detail) }
    }

    private func clearCaption() {
        withAnimation(.easeIn(duration: 0.2)) { world.caption = nil }
    }

    private func press(_ keys: [String], hold: Double = 1.0) {
        world.keysToken += 1
        withAnimation(Motion.bouncy) { world.keys = keys }
        keysClearFrame = frameCounter + Int(hold * DemoEngine.fps)
    }

    private func look(at center: CGPoint, zoom: CGFloat, speed: CGFloat = 4.6) {
        trackedClip = nil
        engine.camera.targetCenter = center
        engine.camera.targetZoom = zoom
        engine.camera.omega = speed
    }

    private func lookAtStage() {
        look(at: CGPoint(x: 800, y: 450), zoom: 1)
    }

    private func lookAtStrip() {
        look(at: CGPoint(x: 800, y: 450), zoom: DemoCamera.fillZoom)
    }

    private func cardFrame(_ index: Int) -> CGRect {
        DemoStageLayout.cardFrame(index: index, scrollOffset: model.demoStripOffset)
    }

    /// Mirrors what CardStrip does with a window: keeps the selected card clear of the edges.
    private func driveStrip() {
        if stripIdentity != model.listIdentity {
            stripIdentity = model.listIdentity
            model.demoStripOffset = 0
        }
        guard let index = model.clips.firstIndex(where: { $0.id == model.selectedID }) else { return }
        let visible = DemoCamera.stage.width - Metrics.shelfMargin * 2
        let leading = CGFloat(index) * (Metrics.cardWidth + Metrics.cardSpacing)
        let trailing = leading + Metrics.cardWidth + Metrics.stripInset * 2
        let offset = model.demoStripOffset
        let target = leading < offset ? leading : (trailing > offset + visible ? trailing - visible : offset)
        if target != offset {
            withAnimation(Motion.snappy) { model.demoStripOffset = target }
        }
    }

    /// Keeps a card in shot even while the strip scrolls under it.
    private func follow(_ index: Int, zoom: CGFloat = 2.2) {
        guard model.clips.indices.contains(index) else { return }
        engine.camera.omega = 4.6
        trackedClip = (model.clips[index].id, zoom)
    }

    private func showCursor(at point: CGPoint) {
        world.cursorStagePoint = point
        withAnimation(.easeOut(duration: 0.2)) { world.cursorVisible = true }
    }

    private func hideCursor() {
        withAnimation(.easeOut(duration: 0.2)) { world.cursorVisible = false }
    }

    /// Glides the pointer along a soft curve, easing in and out like a hand would.
    private func moveCursor(to end: CGPoint, duration: Double? = nil, trackHover: Bool = false, ghost: Bool = false) async {
        let start = world.cursorStagePoint
        let distance = hypot(end.x - start.x, end.y - start.y)
        let length = duration ?? min(max(0.42, Double(distance) / 900), 1.05)
        let frames = max(Int(length * DemoEngine.fps), 1)
        let normal = CGVector(dx: -(end.y - start.y), dy: end.x - start.x)
        let bow = min(distance * 0.12, 60) / max(distance, 1)
        let control = CGPoint(x: (start.x + end.x) / 2 + normal.dx * bow, y: (start.y + end.y) / 2 + normal.dy * bow)
        for frame in 1...frames {
            let raw = CGFloat(frame) / CGFloat(frames)
            let t = raw * raw * raw * (raw * (raw * 6 - 15) + 10)
            let u = 1 - t
            let point = CGPoint(
                x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
            world.cursorStagePoint = point
            if trackHover { updateHover(at: point) }
            // The card hangs below the pointer, the way it does when you grab it by its header.
            if ghost { world.dragGhost?.point = CGPoint(x: point.x + 40, y: point.y + 118) }
            await engine.frame()
        }
    }

    private func updateHover(at point: CGPoint) {
        for (index, clip) in model.clips.enumerated() {
            let frame = cardFrame(index)
            if frame.contains(point) {
                let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    DemoControl.shared.hover = DemoControl.Hover(clipID: clip.id, point: local)
                }
                return
            }
        }
        if DemoControl.shared.hover != nil {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { DemoControl.shared.hover = nil }
        }
    }

    private func click() async {
        world.cursorPressed = true
        world.ripplePoint = world.cursorStagePoint
        world.rippleProgress = 0
        ripple = (frameCounter, 34)
        await wait(0.09)
        world.cursorPressed = false
        await wait(0.08)
    }

    private func clickAt(_ point: CGPoint, duration: Double? = nil) async {
        await moveCursor(to: point, duration: duration)
        await click()
    }

    private func burst(at point: CGPoint) {
        world.bursts.append(PawBurst(origin: point))
    }

    private func openShelf() async {
        model.isDirectPasteEnabled = DemoControl.shared.isTrusted
        model.isPresented = false
        model.prepareForShow(target: finder)
        await wait(0.03)
        withAnimation(Motion.shelfIn) { model.isPresented = true }
    }

    private func closeShelf() async {
        withAnimation(.easeIn(duration: 0.15)) { model.isPresented = false }
        await wait(0.16)
    }

    private func type(_ text: String, into set: (String) -> Void, perCharacter: Double = 0.075) async {
        var value = ""
        for character in text {
            value.append(character)
            set(value)
            await wait(perCharacter)
        }
    }

    private func addBlock(_ kind: DemoWorld.DocBlock.Kind, fresh: Bool = false) -> UUID {
        let block = DemoWorld.DocBlock(kind: kind)
        withAnimation(Motion.snappy) {
            world.docBlocks.append(block)
            if fresh { world.freshBlockID = block.id }
        }
        return block.id
    }

    private func clearFresh() {
        withAnimation(.easeOut(duration: 0.4)) { world.freshBlockID = nil }
    }

    private func resetDocument() {
        withAnimation(Motion.snappy) { world.docBlocks.removeLast(max(world.docBlocks.count - 2, 0)) }
    }

    private func land(_ clip: Clip, plain: Bool) async {
        _ = writer.write(clip, plainText: plain)
        try? store.recordPaste(clipID: clip.id, targetBundleID: "com.apple.finder")
        let full = (try? store.fullText(clipID: clip.id)) ?? clip.preview ?? ""
        let kind: DemoWorld.DocBlock.Kind
        switch clip.kind {
        case .text:
            let isRich = !plain && clip.source.bundleID == "com.apple.TextEdit"
            kind = isRich ? .rich(full) : .body(full)
        case .link: kind = .link(full)
        case .code: kind = .code(full)
        case .color: kind = .color(ClipColor.parse(full) ?? ClipColor.parse("#000000")!, full)
        case .image:
            let data = (try? store.payload(for: clip))?.first?.first?.data
            kind = .image(data.flatMap(NSImage.init(data:)) ?? NSImage())
        case .file: kind = .body(full)
        }
        _ = addBlock(kind, fresh: true)
    }

    private func paste(_ clip: Clip, plain: Bool = false) async {
        withAnimation(.easeIn(duration: 0.13)) { model.flyingClipID = clip.id }
        await closeShelf()
        await wait(0.05)
        await land(clip, plain: plain)
    }

    private func flashStatus() {
        withAnimation(Motion.bouncy) { world.statusFlash = true }
        flashClearFrame = frameCounter + Int(0.9 * DemoEngine.fps)
    }

    private func clip(where match: (Clip) -> Bool) -> Int? {
        model.clips.firstIndex(where: match)
    }

    private func select(_ index: Int) {
        guard model.clips.indices.contains(index) else { return }
        model.select(model.clips[index])
    }

    // MARK: The film

    func run() async {
        engine.setAppearance(dark: false)
        DemoControl.shared.isTrusted = true
        world.docBlocks = [
            DemoWorld.DocBlock(kind: .title("Mochi's first week")),
            DemoWorld.DocBlock(kind: .body("Mochi comes home on Thursday. Hide the hair ties, move the plants up high, and buy more feather wands.")),
        ]
        model.bottomGap = DemoStageLayout.bottomGap

        await section("intro") { await intro() }
        await section("copy") { await copyScene() }
        await section("open") { await openScene() }
        await section("tour") { await tourScene() }
        await section("hover") { await hoverScene() }
        await section("numbers") { await numbersScene() }
        await section("paste") { await pasteScene() }
        await section("search") { await searchScene() }
        await section("filters") { await filterScene() }
        await section("preview") { await previewScene() }
        await section("pinboards") { await pinboardScene() }
        await section("suggested") { await suggestedScene() }
        await section("organize") { await organizeScene() }
        await section("stack") { await stackScene() }
        await section("settings") { await settingsScene() }
        await section("ai") { await aiScene() }
        await section("dark") { await darkScene() }
        await section("outro") { await outro() }
    }

    private func intro() async {
        engine.camera.center = CGPoint(x: 800, y: 450)
        engine.camera.zoom = 0.9
        engine.camera.targetZoom = 0.9
        world.titleCard = .intro
        await wait(0.25)
        withAnimation(Motion.bouncy) { world.titleRevealed = true }
        await wait(3.4)
        engine.snap("intro")
        look(at: CGPoint(x: 800, y: 450), zoom: 1, speed: 3.2)
        withAnimation(.easeInOut(duration: 0.6)) { world.titleCard = nil }
        await wait(0.9)
        world.titleRevealed = false
    }

    private func copyScene() async {
        caption("Copy anything, in any app", "Text, links, images, files, colors and code.")
        await wait(0.6)
        let line = world.docBlocks[1]
        showCursor(at: CGPoint(x: 1100, y: 600))
        look(at: CGPoint(x: 800, y: 300), zoom: 1.7)
        await wait(0.3)
        await moveCursor(to: CGPoint(x: 382, y: 196))
        world.cursorPressed = true
        await moveCursor(to: CGPoint(x: 1148, y: 196), duration: 0.6)
        world.cursorPressed = false
        withAnimation(.easeOut(duration: 0.12)) { world.selectedBlockID = line.id }
        await wait(0.3)
        press(["⌘", "C"], hold: 1.0)
        await wait(0.35)
        _ = DemoSeed.captureText(
            "Mochi comes home on Thursday. Hide the hair ties, move the plants up high, and buy more feather wands.",
            app: "com.apple.Notes", name: "Notes", store: store)
        hideCursor()
        look(at: CGPoint(x: 1400, y: 90), zoom: 3.2, speed: 4.2)
        caption("Every copy is saved", "A quick check in the menu bar, and it's in your history.")
        await wait(0.65)
        flashStatus()
        await wait(0.4)
        engine.snap("copy-flash")
        await wait(1.3)
        withAnimation(.easeOut(duration: 0.3)) { world.selectedBlockID = nil }
        lookAtStage()
        await wait(0.9)
    }

    private func openScene() async {
        caption("⇧⌘V opens your whole history", "It rises over whatever you're doing, and you never leave your app.")
        press(["⇧", "⌘", "V"], hold: 1.2)
        await wait(0.35)
        lookAtStrip()
        await openShelf()
        await wait(2.2)
        engine.snap("open")
        await wait(0.6)
    }

    private func tourScene() async {
        caption("Every clip, at a glance", "Each one wears the color of the app it came from.")
        follow(0)
        await wait(2.2)
        engine.snap("tour-text")
        press(["→"], hold: 0.5)
        model.moveSelection(by: 1)
        follow(1)
        caption("Arrow keys glide between clips", "Long messages show as much as fits.")
        await wait(2.1)
        press(["→"], hold: 0.5)
        model.moveSelection(by: 1)
        follow(2)
        caption("Links", "With the page's title, image and icon.")
        await wait(2.3)
        engine.snap("tour-link")
        press(["→"], hold: 0.5)
        model.moveSelection(by: 1)
        follow(3)
        caption("Images", "Every picture you copy, even the eleventh of the same kitten.")
        await wait(2.5)
        engine.snap("tour-image")
        press(["→"], hold: 0.5)
        model.moveSelection(by: 1)
        follow(4)
        caption("Code", "Spotted automatically, and colored like an editor would.")
        await wait(2.3)
        engine.snap("tour-code")
        press(["→"], hold: 0.5)
        model.moveSelection(by: 1)
        follow(5)
        caption("Colors", "Hex, RGB and HSL, shown as the real thing. This one's nose pink.")
        await wait(2.4)
        press(["→"], hold: 0.5)
        model.moveSelection(by: 1)
        follow(6)
        caption("Files", "Live thumbnails, ready to paste or drag anywhere.")
        await wait(2.3)
        engine.snap("tour-file")
        press(["→"], hold: 0.5)
        model.moveSelection(by: 1)
        follow(7)
        caption("Secrets stay hidden", "Keys and tokens show as dots, and still paste in full.")
        await wait(2.3)
        engine.snap("tour-secret")
        press(["⌘", "←"], hold: 0.7)
        model.selectFirst()
        lookAtStrip()
        await wait(1.0)
    }

    private func hoverScene() async {
        caption("Cards respond to your pointer", "A little tilt, a little shine, and quick actions when you need them.")
        guard let photoIndex = clip(where: { $0.kind == .image }) else { return }
        let photo = cardFrame(photoIndex)
        showCursor(at: CGPoint(x: photo.midX, y: 700))
        look(at: CGPoint(x: photo.midX + 30, y: photo.midY - 60), zoom: 2.05, speed: 4)
        await wait(0.4)
        await moveCursor(to: CGPoint(x: photo.minX + 40, y: photo.minY + 60), trackHover: true)
        await moveCursor(to: CGPoint(x: photo.maxX - 40, y: photo.maxY - 70), duration: 0.9, trackHover: true)
        engine.snap("hover")
        await moveCursor(to: CGPoint(x: photo.midX, y: photo.minY + 110), duration: 0.6, trackHover: true)
        let next = cardFrame(photoIndex - 1)
        await moveCursor(to: CGPoint(x: next.midX - 30, y: next.midY), duration: 0.7, trackHover: true)
        await wait(0.35)
        await moveCursor(to: CGPoint(x: next.midX - 50, y: 860), duration: 0.5, trackHover: true)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { DemoControl.shared.hover = nil }
        hideCursor()
        await wait(0.2)
    }

    private func numbersScene() async {
        caption("Hold ⌘ for instant picks", "⌘1 through ⌘9 paste any clip you can see.")
        lookAtStrip()
        await wait(0.4)
        press(["⌘"], hold: 1.9)
        withAnimation(Motion.snappy) { model.commandHeld = true }
        await wait(1.0)
        look(at: CGPoint(x: 520, y: 700), zoom: 2.1)
        await wait(1.0)
        engine.snap("numbers")
        withAnimation(Motion.snappy) { model.commandHeld = false }
        await wait(0.3)
    }

    private func pasteScene() async {
        caption("↩ pastes where you left off", "The shelf gets out of the way, and the clip lands in your app.")
        lookAtStrip()
        select(1)
        await wait(0.8)
        press(["↩"], hold: 0.8)
        await wait(0.12)
        if let message = model.selectedClip {
            look(at: CGPoint(x: 800, y: 300), zoom: 1.65, speed: 4)
            await paste(message)
        }
        await wait(1.4)
        engine.snap("paste-text")
        clearFresh()

        caption("Photos paste just the same", "Any picture you've copied, dropped right into your work.")
        press(["⇧", "⌘", "V"], hold: 0.8)
        await wait(0.2)
        lookAtStrip()
        await openShelf()
        await wait(0.9)
        if let photoIndex = clip(where: { $0.kind == .image }) {
            select(photoIndex)
            follow(photoIndex, zoom: 2.0)
            await wait(1.2)
            press(["↩"], hold: 0.8)
            await wait(0.12)
            if let photo = model.selectedClip {
                look(at: CGPoint(x: 800, y: 350), zoom: 1.6, speed: 4)
                await paste(photo)
                await wait(0.3)
                burst(at: CGPoint(x: 500, y: 420))
            }
        }
        await wait(1.6)
        engine.snap("paste-photo")
        clearFresh()

        press(["⇧", "⌘", "V"], hold: 0.8)
        await wait(0.2)
        lookAtStrip()
        await openShelf()
        await wait(0.9)
        if let rich = clip(where: { $0.source.bundleID == "com.apple.TextEdit" }) {
            select(rich)
            follow(rich, zoom: 2.0)
            caption("Formatting comes along", "Rich text stays rich when you paste it.")
            await wait(1.4)
            press(["↩"], hold: 0.8)
            await wait(0.12)
            if let clip = model.selectedClip {
                look(at: CGPoint(x: 800, y: 380), zoom: 1.6, speed: 4)
                await paste(clip)
            }
            await wait(1.2)
            clearFresh()

            await openShelf()
            lookAtStrip()
            await wait(0.8)
            caption("⇧↩ leaves it behind", "Hold ⇧ to paste the same clip as plain text.")
            press(["⇧", "↩"], hold: 1.0)
            await wait(0.3)
            if let clip = model.clips.first {
                look(at: CGPoint(x: 800, y: 400), zoom: 1.6, speed: 4)
                await paste(clip, plain: true)
            }
            await wait(1.4)
            engine.snap("paste-plain")
            clearFresh()
        }
        resetDocument()
        lookAtStage()
        await wait(0.5)
    }

    private func searchScene() async {
        caption("Just start typing", "Search covers everything you've ever copied.")
        press(["⇧", "⌘", "V"], hold: 0.8)
        await openShelf()
        lookAtStrip()
        await wait(0.8)
        look(at: CGPoint(x: 420, y: 650), zoom: 2.2)
        await wait(0.45)
        await type("sweater", into: { self.model.query = $0 })
        await wait(0.7)
        caption("Matches light up", "Long clips jump to the part you were looking for.")
        await wait(2.2)
        engine.snap("search-text")
        press(["⎋"], hold: 0.5)
        model.query = ""
        await wait(0.6)
        caption("Even text inside images", "Clipboard reads your pictures and receipts, right on your Mac.")
        await type("catnip", into: { self.model.query = $0 })
        await wait(0.6)
        if model.clips.first != nil {
            let frame = cardFrame(0)
            look(at: CGPoint(x: frame.midX + 110, y: frame.midY - 50), zoom: 2.5)
        }
        await wait(2.2)
        engine.snap("search-image")
        press(["⎋"], hold: 0.5)
        model.query = ""
        lookAtStrip()
        await wait(0.8)
    }

    private func filterScene() async {
        caption("Filter by kind", "One click for just the links, images, files, colors or code.")
        let barY = DemoStageLayout.shelfY + 27
        let x = { (fromRight: CGFloat) in 1590 - fromRight }
        look(at: CGPoint(x: 1150, y: 650), zoom: 2.0)
        showCursor(at: CGPoint(x: 1150, y: 720))
        await wait(0.4)
        await clickAt(CGPoint(x: x(224), y: barY))
        model.toggleKind(.image)
        lookAtStrip()
        caption("All kittens, all the time", "Every picture you've copied, in one row.")
        await wait(2.2)
        engine.snap("filter-images")
        caption("One click to switch", "Just the code, just the colors. One more click clears it.")
        await clickAt(CGPoint(x: x(134), y: barY), duration: 0.5)
        model.toggleKind(.code)
        await wait(1.5)
        engine.snap("filter-code")
        await clickAt(CGPoint(x: x(164), y: barY), duration: 0.4)
        model.toggleKind(.color)
        await wait(1.4)
        await clickAt(CGPoint(x: x(164), y: barY), duration: 0.3)
        model.toggleKind(.color)
        hideCursor()
        await wait(0.8)
    }

    private func previewScene() async {
        caption("Space for a closer look", "See all of it, and keep arrowing while it's open.")
        if let image = clip(where: { $0.kind == .image }) {
            select(image)
            await wait(0.5)
            look(at: CGPoint(x: 800, y: 300), zoom: 1.28)
            press(["Space"], hold: 0.9)
            await wait(0.2)
            withAnimation(Motion.bouncy) { model.isPreviewing = true }
            await wait(1.8)
            engine.snap("preview-image")
            clearCaption()
            await wait(0.5)
            press(["→"], hold: 0.5)
            model.moveSelection(by: 1)
            await wait(1.5)
            engine.snap("preview-next")
            press(["⎋"], hold: 0.5)
            withAnimation(.easeIn(duration: 0.12)) { model.isPreviewing = false }
            await wait(0.3)
        }
        lookAtStrip()
        await wait(0.3)
    }

    private func pinboardScene() async {
        caption("Pinboards keep what matters", "Group your favorites. Pinned clips are never deleted.")
        let barY = DemoStageLayout.shelfY + 27
        look(at: CGPoint(x: 413, y: 600), zoom: 2.2)
        showCursor(at: CGPoint(x: 620, y: 700))
        await wait(0.5)
        await clickAt(CGPoint(x: 557, y: barY))
        model.beginNewPinboard()
        await wait(0.6)
        engine.snap("pinboard-new")
        await clickAt(CGPoint(x: 166, y: barY), duration: 0.6)
        withAnimation(Motion.bouncy) { model.editColor = "rose" }
        await wait(0.3)
        hideCursor()
        await type("Cutest", into: { self.model.editText = $0 }, perCharacter: 0.09)
        await wait(0.35)
        press(["↩"], hold: 0.6)
        model.commitEdit()
        await wait(0.9)

        caption("Drag a clip onto its name", "Or pin it from the card.")
        let photoIndex = clip(where: { $0.kind == .image }) ?? 2
        select(photoIndex)
        let card = cardFrame(photoIndex)
        showCursor(at: CGPoint(x: card.midX - 40, y: card.minY + 14))
        look(at: CGPoint(x: 560, y: 620), zoom: 1.75)
        await wait(0.5)
        if let selected = model.selectedClip, let board = model.pinboards.first(where: { $0.name == "Cutest" }) {
            world.cursorPressed = true
            await wait(0.12)
            withAnimation(Motion.bouncy) {
                world.dragGhost = DemoWorld.DragGhost(
                    clip: selected, point: CGPoint(x: world.cursorStagePoint.x + 40, y: world.cursorStagePoint.y + 118))
            }
            await wait(0.15)
            let chip = CGPoint(x: 590, y: barY)
            await moveCursor(to: chip, duration: 0.9, ghost: true)
            withAnimation(Motion.bouncy) { DemoControl.shared.dropTargetBoardID = board.id }
            await wait(0.5)
            engine.snap("pinboard-drag")
            world.cursorPressed = false
            withAnimation(Motion.bouncy) {
                world.dragGhost = nil
                DemoControl.shared.dropTargetBoardID = nil
            }
            model.pin(clipID: selected.id, to: board)
            burst(at: chip)
            await wait(1.0)
            hideCursor()
            caption("⇥ flips between pinboards", "History, Suggested and every pinboard are one key away.")
            press(["⇥"], hold: 0.5)
            model.setScope(.suggested)
            await wait(0.6)
            press(["⇥"], hold: 0.5)
            if let mochi = model.pinboards.first(where: { $0.name == "Mochi" }) { model.setScope(.pinboard(mochi.id)) }
            lookAtStrip()
            await wait(1.2)
            engine.snap("pinboard-mochi")
            press(["⇥"], hold: 0.5)
            model.setScope(.pinboard(board.id))
            await wait(1.2)
            model.setScope(.history)
            await wait(0.5)
        }
    }

    private func suggestedScene() async {
        caption("Suggested knows your habits", "What you paste into this app, and what you just copied elsewhere.")
        let barY = DemoStageLayout.shelfY + 27
        showCursor(at: CGPoint(x: 500, y: 700))
        look(at: CGPoint(x: 520, y: 640), zoom: 1.75)
        await wait(0.3)
        await clickAt(CGPoint(x: 398, y: barY))
        model.setScope(.suggested)
        hideCursor()
        await wait(1.8)
        engine.snap("suggested")
        model.setScope(.history)
        await wait(0.6)
    }

    private func organizeScene() async {
        caption("Name it, or lose it", "Rename a clip so it's easy to find. ⌘⌫ deletes it for good.")
        if let index = clip(where: { $0.source.bundleID == "com.tinyspeck.slackmacgap" }) {
            select(index)
            follow(index, zoom: 2.0)
            await wait(0.6)
            if let selected = model.selectedClip {
                model.beginRename(selected)
                await wait(0.3)
                await type("Kitten pics for standup", into: { self.model.editText = $0 }, perCharacter: 0.05)
                await wait(0.3)
                press(["↩"], hold: 0.6)
                model.commitEdit()
                await wait(1.3)
                engine.snap("renamed")
            }
        }
        if let index = clip(where: { $0.source.bundleID == "com.apple.Notes" }) {
            select(index)
            lookAtStrip()
            await wait(0.8)
            press(["⌘", "⌫"], hold: 0.8)
            await wait(0.2)
            model.deleteSelected()
            await wait(1.3)
        }
        press(["⎋"], hold: 0.5)
        await closeShelf()
        await wait(0.4)
    }

    private func stackScene() async {
        caption("Paste Stack: copy many, paste in order", "Start it with ⇧⌘C, then copy things one after another.")
        look(at: CGPoint(x: 960, y: 400), zoom: 1.4)
        var stacked: [Clip] = []
        let details = ["Mochi", "12 weeks", "Naps, feather wands, the cursor"]
        let lineIDs = details.map { addBlock(.body($0)) }
        _ = addBlock(.body(" "))
        let labels = ["Name", "Age", "Likes"]
        var fieldIDs: [UUID] = []
        for label in labels { fieldIDs.append(addBlock(.formField(label: label, value: nil))) }
        await wait(0.9)
        press(["⇧", "⌘", "C"], hold: 1.1)
        await wait(0.25)
        stack.start()
        await wait(1.2)
        engine.snap("stack-empty")

        for (index, detail) in details.enumerated() {
            withAnimation(.easeOut(duration: 0.12)) { world.selectedBlockID = lineIDs[index] }
            await wait(0.3)
            press(["⌘", "C"], hold: 0.55)
            await wait(0.3)
            if let clip = DemoSeed.captureText(detail, app: "com.apple.Notes", name: "Notes", store: store) {
                stacked.append(clip)
                stack.add(clip)
            }
            flashStatus()
            await wait(0.55)
        }
        withAnimation(.easeOut(duration: 0.15)) { world.selectedBlockID = nil }
        await wait(0.5)
        engine.snap("stack-full")

        caption("Each ⌘V pastes the next one", "Oldest first, until the stack is empty.")
        await wait(1.4)
        for (index, fieldID) in fieldIDs.enumerated() {
            press(["⌘", "V"], hold: 0.55)
            await wait(0.2)
            if let position = world.docBlocks.firstIndex(where: { $0.id == fieldID }) {
                withAnimation(Motion.snappy) {
                    world.docBlocks[position].kind = .formField(label: labels[index], value: details[index])
                }
            }
            await wait(0.1)
            stack.advance()
            await wait(0.75)
        }
        look(at: CGPoint(x: 800, y: 460), zoom: 1.2)
        burst(at: CGPoint(x: 800, y: 766))
        await wait(1.1)
        engine.snap("stack-done")
        await wait(1.0)
        toast.hideForDemo()
        // Three short lines would crowd the kittens out of the strip in the scenes that follow.
        for clip in stacked { try? store.delete(clipID: clip.id) }
        resetDocument()
        lookAtStage()
        await wait(0.6)
    }

    private func settingsScene() async {
        DemoControl.shared.isTrusted = false
        let frame = DemoStageLayout.settingsFrame
        let sidebarX = frame.minX + 110
        let rowY = { (row: Int) in frame.minY + 139 + CGFloat(row) * 40.5 }

        caption("Settings that get out of your way", "Clean, simple, and all in one place.")
        look(at: CGPoint(x: 800, y: 420), zoom: 1.28, speed: 4)
        withAnimation(Motion.bouncy) { world.settingsVisible = true }
        await wait(2.0)
        engine.snap("settings-general")

        caption("Turn on direct paste once", "One permission, and clips land straight in your apps.")
        look(at: CGPoint(x: frame.minX + 520, y: frame.minY + 170), zoom: 2.1)
        showCursor(at: CGPoint(x: frame.minX + 500, y: frame.minY + 300))
        await wait(0.5)
        await clickAt(CGPoint(x: frame.minX + 703, y: frame.minY + 150))
        await wait(0.4)
        withAnimation(Motion.bouncy) { DemoControl.shared.isTrusted = true }
        await wait(1.6)
        engine.snap("settings-trusted")

        caption("Your library at a glance", "What you've saved, and how much room it takes.")
        look(at: CGPoint(x: frame.minX + 520, y: frame.minY + 450), zoom: 2.0)
        await wait(2.3)
        engine.snap("settings-library")

        caption("Make every shortcut yours", "Click one and type the keys you want.")
        look(at: CGPoint(x: 800, y: 420), zoom: 1.28)
        await clickAt(CGPoint(x: sidebarX, y: rowY(1)), duration: 0.7)
        withAnimation(Motion.snappy) { navigation.page = .shortcuts }
        await wait(0.8)
        look(at: CGPoint(x: frame.minX + 560, y: frame.minY + 190), zoom: 2.0)
        await wait(0.3)
        await clickAt(CGPoint(x: frame.maxX - 90, y: frame.minY + 142))
        withAnimation(Motion.snappy) { DemoControl.shared.recordingShortcut = "open" }
        await moveCursor(to: CGPoint(x: frame.maxX - 170, y: frame.minY + 205), duration: 0.4)
        await wait(0.8)
        engine.snap("settings-recording")
        press(["⌃", "⌥", "V"], hold: 0.8)
        await wait(0.25)
        withAnimation(Motion.bouncy) {
            Preferences.shared.openShortcut = KeyCombo(keyCode: 9, carbonModifiers: UInt32(4096 | 2048))
            DemoControl.shared.recordingShortcut = nil
        }
        await wait(1.2)

        caption("Your clipboard stays yours", "Stored only on this Mac. Skip apps, hide secrets, or pause anytime.")
        look(at: CGPoint(x: 800, y: 420), zoom: 1.28)
        await clickAt(CGPoint(x: sidebarX, y: rowY(2)), duration: 0.6)
        withAnimation(Motion.snappy) { navigation.page = .privacy }
        await wait(1.4)
        engine.snap("settings-privacy")
        look(at: CGPoint(x: frame.minX + 540, y: frame.minY + 215), zoom: 2.0)
        await wait(0.5)
        await clickAt(CGPoint(x: frame.minX + 676, y: frame.minY + 217))
        withAnimation(Motion.snappy) { Preferences.shared.secretHandling = .hide }
        await wait(1.6)
        engine.snap("settings-secrets")
        look(at: CGPoint(x: frame.minX + 540, y: frame.maxY - 150), zoom: 1.9)
        withAnimation(.smooth(duration: 0.8)) { DemoControl.shared.settingsScrollOffset = 206 }
        await wait(1.1)
        await clickAt(CGPoint(x: 1126, y: 629))
        withAnimation(Motion.snappy) { DemoControl.shared.confirmDeleteHistory = true }
        await moveCursor(to: CGPoint(x: 1010, y: 672), duration: 0.5)
        await wait(1.3)
        engine.snap("settings-delete")
        await clickAt(CGPoint(x: 730, y: 649), duration: 0.5)
        withAnimation(Motion.snappy) { DemoControl.shared.confirmDeleteHistory = false }
        await wait(0.6)

        caption("AI tools, on your terms", "Share nothing, just your pinboards, or everything.")
        look(at: CGPoint(x: 800, y: 420), zoom: 1.28)
        await clickAt(CGPoint(x: sidebarX, y: rowY(4)), duration: 0.6)
        DemoControl.shared.settingsScrollOffset = 0
        withAnimation(Motion.snappy) { navigation.page = .aiTools }
        await wait(0.9)
        look(at: CGPoint(x: frame.minX + 520, y: frame.minY + 200), zoom: 1.75)
        await clickAt(CGPoint(x: frame.minX + 515, y: frame.minY + 157), duration: 0.6)
        DemoControl.shared.aiAccess = .pinboards
        await wait(0.8)
        await clickAt(CGPoint(x: frame.minX + 691, y: frame.minY + 157), duration: 0.5)
        DemoControl.shared.aiAccess = .everything
        await wait(1.0)
        engine.snap("settings-ai")
        look(at: CGPoint(x: frame.minX + 520, y: frame.minY + 360), zoom: 1.85)
        await wait(0.5)
        await clickAt(CGPoint(x: frame.maxX - 69, y: frame.minY + 350), duration: 0.6)
        DemoControl.shared.copiedSnippet += 1
        await wait(1.3)
        hideCursor()
        withAnimation(.easeIn(duration: 0.18)) { world.settingsVisible = false }
        withAnimation(Motion.snappy) { navigation.page = .general }
        Preferences.shared.openShortcut = KeyCombo.defaultOpen
        lookAtStage()
        await wait(0.7)
    }

    private func aiScene() async {
        caption("Your AI tools can search it too", "They see only what you chose to share, and they can't change a thing.")
        look(at: CGPoint(x: 800, y: 300), zoom: 1.6)
        withAnimation(Motion.bouncy) { world.consoleVisible = true }
        await wait(0.5)
        await type("clipboard_search  query: \"catnip\"", into: { self.world.consoleText = "> " + $0 }, perCharacter: 0.045)
        await wait(0.4)
        // The real MCP server, answering from this demo's own history.
        let found = askMCP(tool: "clipboard_search", arguments: #"{"query":"catnip"}"#)
        withAnimation(.easeOut(duration: 0.3)) { world.consoleResult = found.pretty }
        await wait(2.0)
        if let id = found.firstID {
            let command = "clipboard_get  id: \(id)"
            await type(command, into: { self.world.consoleText = "> " + $0 }, perCharacter: 0.04)
            await wait(0.3)
            let clip = askMCP(tool: "clipboard_get", arguments: "{\"id\":\(id)}")
            withAnimation(Motion.bouncy) {
                world.consoleResult = clip.pretty
                world.consoleImage = clip.image
            }
            await wait(3.4)
        }
        engine.snap("ai-console")
        withAnimation(.easeIn(duration: 0.2)) { world.consoleVisible = false }
        lookAtStage()
        await wait(0.6)
    }

    private func askMCP(tool: String, arguments: String) -> (pretty: String, firstID: Int?, image: NSImage?) {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":""# + tool + #"","arguments":"# + arguments + "}}"
        guard
            let reply = MCPServer(openStore: { [store] in store }).handle(Data(request.utf8)),
            let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
            let result = object["result"] as? [String: Any],
            let content = result["content"] as? [[String: Any]],
            let text = content.first?["text"] as? String
        else { return ("", nil, nil) }
        let picture = content.first { $0["type"] as? String == "image" }
            .flatMap { $0["data"] as? String }
            .flatMap { Data(base64Encoded: $0) }
            .flatMap(NSImage.init(data:))
        guard
            let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
            let data = try? JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return (text, nil, picture) }
        let first = (parsed as? [[String: Any]])?.first?["id"] as? Int
        return (String(decoding: data, as: UTF8.self), first, picture)
    }

    private func darkScene() async {
        caption("At home in the dark", "Everything follows your Mac's appearance.")
        engine.setAppearance(dark: true)
        withAnimation(.easeInOut(duration: 0.5)) { world.isDark = true }
        await wait(0.6)
        await openShelf()
        lookAtStrip()
        await wait(2.6)
        engine.snap("dark")
        await closeShelf()
        clearCaption()
        lookAtStage()
        await wait(0.5)
    }

    private func outro() async {
        look(at: CGPoint(x: 800, y: 450), zoom: 0.92, speed: 3)
        withAnimation(.easeInOut(duration: 0.55)) { world.titleCard = .outro }
        await wait(0.45)
        withAnimation(Motion.bouncy) { world.titleRevealed = true }
        await wait(4.2)
        engine.snap("outro")
        withAnimation(.easeIn(duration: 0.6)) { world.fadedOut = true }
        await wait(0.75)
    }
}

@MainActor
enum DemoRunner {
    static func start() {
        Task { @MainActor in
            await run()
            NSApp.terminate(nil)
        }
    }

    private static func run() async {
        let environment = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: environment["CLIPBOARD_DEMO_OUTPUT"]!)
        let stills = environment["CLIPBOARD_DEMO_STILLS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let stills { try? FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true) }
        let stillEvery = environment["CLIPBOARD_DEMO_STILL_EVERY"].flatMap(Int.init) ?? 0
        let only = environment["CLIPBOARD_DEMO_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }

        do {
            let store = try ClipStore()
            await DemoSeed.populate(store: store, folder: store.directory.appendingPathComponent("sample-files", isDirectory: true))

            let world = DemoWorld()
            let writer = PasteboardWriter(store: store)
            let toast = ToastController()
            let stack = StackController(writer: writer, toast: toast)
            let model = PanelModel(store: store)
            stack.onChange = { isActive, count in
                model.isStackActive = isActive
                model.stackCount = count
            }
            model.bottomGap = DemoStageLayout.bottomGap
            let navigation = SettingsNavigation()

            let engine = try DemoEngine(
                world: world,
                stageRoot: AnyView(DemoStage(world: world, model: model, stack: stack, toast: toast, store: store, navigation: navigation)),
                overlayRoot: AnyView(DemoOverlay(world: world)),
                output: output, stills: stills, stillEvery: stillEvery)
            let script = DemoScript(
                engine: engine, world: world, model: model, stack: stack, toast: toast, store: store, writer: writer,
                navigation: navigation, onlySections: only)
            let started = Date()
            await script.run()
            await engine.finish()
            if let error = engine.outputError { print("demo: writer error \(error)") }
            print("demo: wrote \(engine.writtenFrames) frames (\(Double(engine.writtenFrames) / DemoEngine.fps)s) in \(Int(Date().timeIntervalSince(started)))s to \(output.path)")
        } catch {
            print("demo: failed \(error)")
        }
    }
}
#endif
