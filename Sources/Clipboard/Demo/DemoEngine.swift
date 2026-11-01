#if DEBUG
import AVFoundation
import AppKit
import ClipboardCore
import CoreImage
import Metal
import QuartzCore
import SwiftUI

/// Hooks the demo uses to drive state that views otherwise keep to themselves.
@MainActor @Observable
final class DemoControl {
    static let shared = DemoControl()

    struct Hover: Equatable {
        let clipID: Int64
        let point: CGPoint
    }

    var isTrusted = false
    var hover: Hover?
    var dropTargetBoardID: Int64?
    var recordingShortcut: String?
    var confirmDeleteHistory = false
    var aiAccess: AIAccess?
    var aiTool: Int?
    var copiedSnippet = 0
    var settingsScrollOffset: CGFloat = 0
}

/// A SwiftUI tree rendered off screen. `_renderForTest` advances SwiftUI's animation clock by an exact interval
/// and CARenderer composites the layers on the GPU, which needs no window, no display and no unlocked session.
@MainActor
final class OffscreenLayerTree {
    let hosting: NSHostingView<AnyView>
    private let renderer: CARenderer
    private let scale: CGFloat
    private let queue: MTLCommandQueue
    let texture: MTLTexture

    init(root: AnyView, size: CGSize, scale: CGFloat, device: MTLDevice, queue: MTLCommandQueue) {
        self.scale = scale
        self.queue = queue
        hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layoutSubtreeIfNeeded()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(size.width * scale), height: Int(size.height * scale), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        texture = device.makeTexture(descriptor: descriptor)!

        renderer = CARenderer(
            mtlTexture: texture,
            options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, kCARendererMetalCommandQueue: queue])
        renderer.layer = hosting.layer
        renderer.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
    }

    func step(_ interval: TimeInterval) {
        hosting._renderForTest(interval: interval)
    }

    func render() {
        guard let root = hosting.layer else { return }
        sharpen(root)
        CATransaction.flush()
        root.displayIfNeeded()
        // Reapplied every frame: AppKit resets it when the view lays out again.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.anchorPoint = .zero
        root.position = .zero
        root.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        CATransaction.flush()
        clear()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let sync = queue.makeCommandBuffer()
        sync?.commit()
        sync?.waitUntilCompleted()
    }

    // CARenderer draws over what's already there, which would leave trails on a see-through tree.
    private func clear() {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.commit()
    }

    // Without a window SwiftUI rasterizes at 1x, which would turn soft under the camera's zoom.
    private func sharpen(_ layer: CALayer) {
        if layer.contentsScale != scale, String(describing: type(of: layer)).contains("CGDrawing") {
            layer.contentsScale = scale
            layer.setNeedsDisplay()
        }
        for sublayer in layer.sublayers ?? [] { sharpen(sublayer) }
    }

    func image() -> CIImage {
        CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])!
    }
}

/// A camera over the stage, moved by critically damped springs so every zoom and pan eases in and out.
struct DemoCamera {
    static let stage = CGSize(width: 1600, height: 900)
    static let canvas = CGSize(width: 2560, height: 1440)
    /// Canvas pixels per stage point at zoom 1, where the stage floats inside the canvas with a margin around it.
    static let baseScale = canvas.width * 0.88 / stage.width
    /// The zoom at which the stage exactly fills the canvas.
    static let fillZoom = canvas.width / (stage.width * baseScale)

    var center = CGPoint(x: stage.width / 2, y: stage.height / 2)
    var zoom: CGFloat = 1
    var targetCenter = CGPoint(x: stage.width / 2, y: stage.height / 2)
    var targetZoom: CGFloat = 1
    var omega: CGFloat = 4.6
    private var velocity = CGVector.zero
    private var zoomVelocity: CGFloat = 0

    private(set) var panSpeed: CGVector = .zero
    private(set) var zoomSpeed: CGFloat = 0

    private static func smooth(_ value: CGFloat, _ target: CGFloat, _ speed: inout CGFloat, omega: CGFloat, dt: CGFloat) -> CGFloat {
        let x = omega * dt
        let decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        let change = value - target
        let temp = (speed + omega * change) * dt
        speed = (speed - omega * temp) * decay
        return target + (change + temp) * decay
    }

    mutating func step(dt: CGFloat) {
        let (oldCenter, oldZoom) = (center, zoom)
        center.x = Self.smooth(center.x, targetCenter.x, &velocity.dx, omega: omega, dt: dt)
        center.y = Self.smooth(center.y, targetCenter.y, &velocity.dy, omega: omega, dt: dt)
        zoom = Self.smooth(zoom, targetZoom, &zoomVelocity, omega: omega, dt: dt)
        clamp()
        let scale = Self.baseScale * zoom
        panSpeed = CGVector(dx: (center.x - oldCenter.x) * scale, dy: (center.y - oldCenter.y) * scale)
        zoomSpeed = (zoom - oldZoom) / max(zoom, 0.01) * Self.canvas.width / 2
    }

    // Keeps the view on the stage once it's zoomed in far enough to have no margin left.
    private mutating func clamp() {
        let scale = Self.baseScale * zoom
        let halfWidth = Self.canvas.width / 2 / scale
        let halfHeight = Self.canvas.height / 2 / scale
        center.x = halfWidth < Self.stage.width / 2
            ? min(max(center.x, halfWidth), Self.stage.width - halfWidth) : Self.stage.width / 2
        center.y = halfHeight < Self.stage.height / 2
            ? min(max(center.y, halfHeight), Self.stage.height - halfHeight) : Self.stage.height / 2
    }

    var scale: CGFloat { Self.baseScale * zoom }

    func project(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: Self.canvas.width / 2 + (point.x - center.x) * scale,
            y: Self.canvas.height / 2 + (point.y - center.y) * scale)
    }
}

@MainActor
final class DemoEngine {
    static let fps: Double = 60
    static let stageScale: CGFloat = 3
    static let overlaySize = CGSize(width: 1280, height: 720)

    let world: DemoWorld
    var camera = DemoCamera()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private let stage: OffscreenLayerTree
    private let overlay: OffscreenLayerTree
    private let background: CIImage
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    private let stillsDirectory: URL?
    private let stillEvery: Int
    private(set) var writtenFrames = 0
    /// While true the script's state still advances, but nothing is drawn or written. Used to preview one section.
    var isFastForwarding = false
    /// Runs once per frame before the views step, for the cursor and anything else that follows the clock.
    var onFrame: (() -> Void)?
    private var startTime: CFTimeInterval = 0

    init(world: DemoWorld, stageRoot: AnyView, overlayRoot: AnyView, output: URL, stills: URL?, stillEvery: Int) throws {
        self.world = world
        stillsDirectory = stills
        self.stillEvery = stillEvery
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        context = CIContext(
            mtlCommandQueue: queue, options: [.workingColorSpace: srgb, .outputColorSpace: srgb, .cacheIntermediates: false])
        stage = OffscreenLayerTree(root: stageRoot, size: DemoCamera.stage, scale: Self.stageScale, device: device, queue: queue)
        overlay = OffscreenLayerTree(root: overlayRoot, size: Self.overlaySize, scale: 2, device: device, queue: queue)

        let renderer = ImageRenderer(content: DemoCanvasBackground().frame(width: Self.overlaySize.width, height: Self.overlaySize.height))
        renderer.scale = 2
        background = CIImage(cgImage: renderer.cgImage!)

        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(DemoCamera.canvas.width),
                AVVideoHeightKey: Int(DemoCamera.canvas.height),
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 18_000_000,
                    AVVideoExpectedSourceFrameRateKey: Int(Self.fps),
                    AVVideoMaxKeyFrameIntervalKey: Int(Self.fps * 2),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(DemoCamera.canvas.width),
                kCVPixelBufferHeightKey as String: Int(DemoCamera.canvas.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func setAppearance(dark: Bool) {
        stage.hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    /// Advances the world by one frame of video.
    func frame() async {
        // Lets detached store reads, thumbnail loads and main-queue work land between frames.
        try? await Task.sleep(nanoseconds: 300_000)
        onFrame?()
        camera.step(dt: CGFloat(1 / Self.fps))
        world.syncCursor(camera: camera)
        let interval = 1 / Self.fps
        stage.step(interval)
        overlay.step(interval)
        guard !isFastForwarding else { return }

        stage.render()
        overlay.render()
        await writeFrame()
        await paceToRealTime()
    }

    func wait(_ seconds: Double) async {
        for _ in 0..<Int((seconds * Self.fps).rounded()) { await frame() }
    }

    // Some effects, like symbol bounces, run on Core Animation's wall clock. Staying close to real time keeps them
    // in step with everything that the frame clock drives.
    private func paceToRealTime() async {
        if startTime == 0 { startTime = CACurrentMediaTime() }
        let due = startTime + Double(writtenFrames) / Self.fps
        let early = due - CACurrentMediaTime()
        if early > 0.001 { try? await Task.sleep(nanoseconds: UInt64(early * 1_000_000_000)) }
    }

    private func composedFrame() -> CIImage {
        let canvas = CGRect(origin: .zero, size: DemoCamera.canvas)
        let scale = camera.scale
        let stageHeight = DemoCamera.stage.height

        // Stage points to canvas pixels, with Core Image's y axis pointing up.
        let tx = canvas.width / 2 - camera.center.x * scale
        let ty = canvas.height / 2 - (stageHeight - camera.center.y) * scale
        let sampled = stage.image()
            .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale / Self.stageScale, "inputAspectRatio": 1])
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))
        let frameRect = CGRect(x: tx, y: ty, width: DemoCamera.stage.width * scale, height: stageHeight * scale)
        let visible = frameRect.intersection(canvas.insetBy(dx: -8, dy: -8))

        // The background drifts a little as the camera moves, which gives the scene some depth.
        let parallax = 1 + (camera.zoom - 1) * 0.05
        let drifted = background.clampedToExtent().transformed(
            by: CGAffineTransform(translationX: canvas.midX, y: canvas.midY)
                .scaledBy(x: parallax, y: parallax)
                .translatedBy(x: -canvas.midX - (camera.center.x - DemoCamera.stage.width / 2) * 0.03,
                              y: -canvas.midY + (camera.center.y - DemoCamera.stage.height / 2) * 0.03))

        var result = drifted
        // Clamped first, so the blurs have real pixels to sample at the frame's edges.
        var picture = motionBlurred(sampled.clampedToExtent(), canvas: canvas).cropped(to: visible)

        if camera.zoom < DemoCamera.fillZoom + 0.06 {
            let radius = 15 * scale
            let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.55))
                .cropped(to: frameRect.offsetBy(dx: 0, dy: -18))
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 46])
            result = shadow.composited(over: result)
            let mask = CIFilter(
                name: "CIRoundedRectangleGenerator",
                parameters: ["inputExtent": CIVector(cgRect: frameRect), "inputRadius": radius, "inputColor": CIColor.white]
            )!.outputImage!
            picture = picture.applyingFilter(
                "CIBlendWithAlphaMask",
                parameters: ["inputBackgroundImage": CIImage.empty(), "inputMaskImage": mask])
        }

        result = picture.composited(over: result)
        return overlay.image().composited(over: result).cropped(to: canvas)
    }

    // A touch of blur while the camera is moving fast, the way a real lens would smear it.
    private func motionBlurred(_ image: CIImage, canvas: CGRect) -> CIImage {
        let pan = hypot(camera.panSpeed.dx, camera.panSpeed.dy)
        let zoomRate = abs(camera.zoomSpeed)
        var output = image
        if zoomRate > 6 {
            output = output.applyingFilter(
                "CIZoomBlur",
                parameters: ["inputCenter": CIVector(x: canvas.midX, y: canvas.midY), "inputAmount": min((zoomRate - 6) * 0.05, 1.6)])
        }
        if pan > 6 {
            output = output.applyingFilter(
                "CIMotionBlur",
                parameters: ["inputRadius": min((pan - 6) * 0.09, 4.5), "inputAngle": atan2(camera.panSpeed.dy, camera.panSpeed.dx)])
        }
        return output
    }

    private func writeFrame() async {
        let image = composedFrame()
        guard let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: DemoCamera.canvas), colorSpace: srgb)
        while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 1_000_000) }
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(writtenFrames), timescale: CMTimeScale(Self.fps)))
        if let stillsDirectory, stillEvery > 0, writtenFrames % stillEvery == 0 {
            saveStill(image, to: stillsDirectory.appendingPathComponent(String(format: "f%06d.jpg", writtenFrames)))
        }
        writtenFrames += 1
    }

    func snap(_ name: String) {
        guard !isFastForwarding, let stillsDirectory else { return }
        saveStill(composedFrame(), to: stillsDirectory.appendingPathComponent("\(name).jpg"))
    }

    private func saveStill(_ image: CIImage, to url: URL) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        try? context.writeJPEGRepresentation(
            of: image.cropped(to: CGRect(origin: .zero, size: DemoCamera.canvas)), to: url, colorSpace: srgb,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
    }

    func finish() async {
        input.markAsFinished()
        await writer.finishWriting()
    }

    var outputError: Error? { writer.error }
}
#endif
