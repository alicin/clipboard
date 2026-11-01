// Draws Clipboard's app icon, a holographic clipboard sticker on a dark tile. Run from the repo root:
//   swiftc -o /tmp/make-icon scripts/make-icon.swift && /tmp/make-icon
import AppKit

let size: CGFloat = 1024
let canvas = CGRect(x: 0, y: 0, width: size, height: size)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [UInt32], alpha: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors.enumerated().map { color($1, alpha?[$0] ?? 1) } as CFArray, locations: nil)!
}

func newContext() -> CGContext {
    CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// Apple's icon grid: an 824 px square with continuous corners, centred on the 1024 px canvas.
func tile(border: CGColor? = nil) -> CGImage {
    let shape = CALayer()
    shape.frame = CGRect(x: 100, y: 100, width: 824, height: 824)
    shape.cornerRadius = 185.4
    shape.cornerCurve = .continuous
    if let border {
        shape.borderColor = border
        shape.borderWidth = 4
    } else {
        shape.backgroundColor = color(0xffffff)
    }
    let layer = CALayer()
    layer.frame = canvas
    layer.addSublayer(shape)
    let context = newContext()
    layer.render(in: context)
    return context.makeImage()!
}

// Coordinates are relative to the sticker's centre, with y up.
private let boardRect = CGRect(x: -196, y: -262, width: 392, height: 470)
private let clipRect = CGRect(x: -98, y: 148, width: 196, height: 118)

func stickerTransform() -> CGAffineTransform {
    CGAffineTransform(translationX: size / 2, y: size / 2 - 4).rotated(by: -9 * .pi / 180)
}

func placed(_ path: CGPath) -> CGPath {
    var place = stickerTransform()
    return path.copy(using: &place)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Core Graphics has no conic gradient, so the holographic sweep is a fan of thin wedges.
func holo(_ context: CGContext, center: CGPoint, _ stops: [UInt32]) {
    let steps = 360
    func channel(_ hex: UInt32, _ shift: UInt32) -> CGFloat { CGFloat(hex >> shift & 0xff) / 255 }
    for step in 0..<steps {
        let t = CGFloat(step) / CGFloat(steps) * CGFloat(stops.count - 1)
        let index = min(Int(t), stops.count - 2)
        let mix = t - CGFloat(index)
        let (a, b) = (stops[index], stops[index + 1])
        context.setFillColor(
            CGColor(
                srgbRed: channel(a, 16) * (1 - mix) + channel(b, 16) * mix,
                green: channel(a, 8) * (1 - mix) + channel(b, 8) * mix,
                blue: channel(a, 0) * (1 - mix) + channel(b, 0) * mix, alpha: 1))
        context.move(to: center)
        context.addArc(
            center: center, radius: size, startAngle: CGFloat(step) / CGFloat(steps) * 2 * .pi,
            endAngle: CGFloat(step + 1) / CGFloat(steps) * 2 * .pi + 0.01, clockwise: false)
        context.closePath()
        context.fillPath()
    }
}

func render() -> CGImage {
    let context = newContext()
    let shape = tile()
    let everywhere: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    context.draw(shape, in: canvas)
    context.restoreGState()

    context.saveGState()
    context.clip(to: canvas, mask: shape)
    context.drawLinearGradient(
        gradient([0x12404f, 0x07171f]), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: everywhere)
    context.restoreGState()
    // A faint rim keeps the tile's edge visible on a dark Dock.
    context.draw(tile(border: color(0xffffff, 0.14)), in: canvas)

    let board = placed(roundedRect(boardRect, 76))
    let clip = placed(roundedRect(clipRect, 42))

    // The white die-cut border follows the outline of the board and clip together.
    let outline = CGMutablePath()
    outline.addPath(board)
    outline.addPath(clip)
    let backing = CGMutablePath()
    backing.addPath(outline.copy(strokingWithWidth: 56, lineCap: .round, lineJoin: .round, miterLimit: 10))
    backing.addPath(outline)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: color(0x000000, 0.28))
    context.addPath(backing)
    context.setFillColor(color(0xffffff))
    context.fillPath(using: .winding)
    context.restoreGState()

    // The board.
    // Off the sticker: the wedges of the sweep pinch into visible artifacts where they meet.
    let sweepCenter = CGPoint(x: 150, y: 860)
    context.saveGState()
    context.addPath(board)
    context.clip()
    holo(context, center: sweepCenter, [0x19f0c4, 0x2fe6ff, 0x4aa8ff, 0x8f8dff, 0x2fe6ff, 0x19f0c4])
    context.drawLinearGradient(
        gradient([0xffffff, 0xffffff, 0xffffff], alpha: [0, 0.42, 0]), start: CGPoint(x: 260, y: 300),
        end: CGPoint(x: 760, y: 800), options: everywhere)
    context.restoreGState()

    // Lines of text on the board, the same white as the border.
    context.saveGState()
    context.concatenate(stickerTransform())
    context.setFillColor(color(0xffffff, 0.95))
    let lines: [(y: CGFloat, width: CGFloat)] = [(36, 256), (-46, 256), (-128, 164)]
    for line in lines {
        context.addPath(roundedRect(CGRect(x: -128, y: line.y, width: line.width, height: 46), 23))
        context.fillPath()
    }
    context.restoreGState()

    // The clip sits on top of the board, with a white gap around it like the toes of a paw sticker.
    context.saveGState()
    context.addPath(clip.copy(strokingWithWidth: 34, lineCap: .round, lineJoin: .round, miterLimit: 10))
    context.setFillColor(color(0xffffff))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(clip)
    context.clip()
    holo(context, center: CGPoint(x: 900, y: 900), [0xb7ff6a, 0x19f0c4, 0x2fe6ff, 0x19f0c4, 0xb7ff6a])
    context.restoreGState()

    return context.makeImage()!
}

func write(_ image: CGImage, pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let image = render()
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardIcon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    write(image, pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    write(image, pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
write(image, pixels: 1024, to: root.appendingPathComponent("Resources/AppIcon.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and Resources/AppIcon.png" : "iconutil failed")
