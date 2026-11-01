import AppKit
import ClipboardCore
import QuickLookThumbnailing
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.07, green: 0.84, blue: 0.75)
    static let accentTop = Color(red: 0.40, green: 0.95, blue: 0.86)
    static let accentDeep = Color(red: 0.0, green: 0.60, blue: 0.56)
    /// White on this turquoise fails contrast at small sizes, so text on it is a deep teal.
    static let onAccent = Color(red: 0.0, green: 0.19, blue: 0.18)
    static let accentGradient = LinearGradient(colors: [accentTop, accent], startPoint: .top, endPoint: .bottom)
    static let ringGradient = LinearGradient(
        colors: [accentTop, Color(red: 0.08, green: 0.72, blue: 0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let tileSlate = Color(red: 0.36, green: 0.50, blue: 0.56)
    static let tileSky = Color(red: 0.22, green: 0.64, blue: 1.0)
    static let tileMint = Color(red: 0.16, green: 0.78, blue: 0.58)
    static let tileIris = Color(red: 0.53, green: 0.46, blue: 0.98)
    static let tileSun = Color(red: 1.0, green: 0.71, blue: 0.20)

    /// Solid rather than `.primary.opacity`: anything on the shelf inherits the glass's vibrancy, which
    /// would turn a faint tint into a heavy gray even on an opaque card.
    static let cardPaper = dynamic(light: NSColor.white, dark: NSColor(srgbRed: 0.10, green: 0.135, blue: 0.15, alpha: 1))
    static let cardTint = dynamic(
        light: NSColor(srgbRed: 0.94, green: 0.97, blue: 0.97, alpha: 1), dark: NSColor(srgbRed: 0.15, green: 0.19, blue: 0.21, alpha: 1))
    static let codeBackground = Color(red: 0.055, green: 0.11, blue: 0.13)
    static let settingsCard = dynamic(light: NSColor(white: 1, alpha: 0.75), dark: NSColor(white: 1, alpha: 0.055))

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
    }
}

enum Motion {
    static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static var snappy: Animation { isReduced ? .easeOut(duration: 0.1) : .spring(response: 0.3, dampingFraction: 0.84) }
    static var bouncy: Animation { isReduced ? .easeOut(duration: 0.1) : .spring(response: 0.42, dampingFraction: 0.68) }
    static var shelfIn: Animation { isReduced ? .easeOut(duration: 0.12) : .spring(response: 0.46, dampingFraction: 0.8) }
}

enum Metrics {
    static let cardWidth: CGFloat = 228
    static let cardHeight: CGFloat = 250
    static let cardRadius: CGFloat = 18
    static let cardSpacing: CGFloat = 14
    static let stripInset: CGFloat = 22
    static let barHeight: CGFloat = 54
    static let shelfRadius: CGFloat = 30
    static let shelfHeight: CGFloat = barHeight + cardHeight + 42
    /// Clear space above the shelf, so its spring can overshoot without being cut off by the window edge.
    static let windowTopInset: CGFloat = 28
    static let shelfMargin: CGFloat = 10
}

extension View {
    /// The window behind this stays transparent with no shadow of its own, so the shape here is the only edge.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.28), radius: 20, y: 8)
        }
    }
}

struct Keycap: View {
    let text: String
    var isSmall = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: isSmall ? 5 : 7, style: .continuous) }

    var body: some View {
        Text(text)
            .font(.system(size: isSmall ? 11 : 13.5, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .frame(minWidth: isSmall ? 20 : 28, minHeight: isSmall ? 20 : 28)
            .padding(.horizontal, isSmall ? 4 : 6)
            .background {
                shape.fill(Theme.cardPaper)
                    .shadow(color: .black.opacity(0.22), radius: 0, y: isSmall ? 1 : 1.5)
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            }
            .overlay { shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
    }
}

enum PinboardPalette {
    static let names = ["coral", "amber", "moss", "sky", "iris", "rose"]

    static func color(_ name: String) -> Color {
        switch name {
        case "coral": Color(red: 1.0, green: 0.48, blue: 0.40)
        case "amber": Color(red: 1.0, green: 0.76, blue: 0.24)
        case "moss": Color(red: 0.18, green: 0.85, blue: 0.63)
        case "sky": Color(red: 0.25, green: 0.70, blue: 1.0)
        case "iris": Color(red: 0.55, green: 0.48, blue: 1.0)
        case "rose": Color(red: 1.0, green: 0.44, blue: 0.68)
        default: .gray
        }
    }
}

extension ClipKind {
    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    var pluralName: String {
        switch self {
        case .text: "Text"
        case .link: "Links"
        case .image: "Images"
        case .file: "Files"
        case .color: "Colors"
        case .code: "Code"
        }
    }

    var tint: Color {
        switch self {
        case .text: Color(red: 0.48, green: 0.57, blue: 0.61)
        case .link: Color(red: 0.22, green: 0.66, blue: 1.0)
        case .image: Color(red: 0.56, green: 0.49, blue: 1.0)
        case .file: Color(red: 0.07, green: 0.77, blue: 0.69)
        case .color: Color(red: 1.0, green: 0.44, blue: 0.68)
        case .code: Color(red: 0.35, green: 0.84, blue: 0.55)
        }
    }
}

extension ClipColor {
    var swiftUIColor: Color { Color(red: red, green: green, blue: blue, opacity: alpha) }
    var readableForeground: Color { luminance > 0.4 || alpha < 0.5 ? .black.opacity(0.85) : .white }
}

/// Each card's header takes its color from the source app's icon, so the shelf reads by origin at a glance.
@MainActor
final class AppAppearance {
    static let shared = AppAppearance()

    struct Style {
        let icon: NSImage?
        let color: Color
        let colorTop: Color
        let foreground: Color
    }

    private var cache: [String: Style] = [:]
    private static let fallback = makeStyle(icon: nil, rgb: (0.42, 0.45, 0.50))

    private static func makeStyle(icon: NSImage?, rgb: (Double, Double, Double)) -> Style {
        let luminance = 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
        let lifted = (rgb.0 + (1 - rgb.0) * 0.16, rgb.1 + (1 - rgb.1) * 0.16, rgb.2 + (1 - rgb.2) * 0.16)
        return Style(
            icon: icon,
            color: Color(red: rgb.0, green: rgb.1, blue: rgb.2),
            colorTop: Color(red: lifted.0, green: lifted.1, blue: lifted.2),
            foreground: luminance > 0.6 ? .black.opacity(0.85) : .white)
    }

    func style(for bundleID: String?) -> Style {
        guard let bundleID else { return Self.fallback }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            cache[bundleID] = Self.fallback
            return Self.fallback
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let style = Self.makeStyle(icon: icon, rgb: Self.dominantColor(of: icon) ?? (0.42, 0.45, 0.50))
        cache[bundleID] = style
        return style
    }

    // Picks the strongest hue rather than averaging: a plain average of a colorful icon comes out as mud.
    private static func dominantColor(of icon: NSImage) -> (Double, Double, Double)? {
        let side = 32
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var bins = [(weight: Double, red: Double, green: Double, blue: Double)](repeating: (0, 0, 0, 0), count: 12)
        var total = (weight: 0.0, red: 0.0, green: 0.0, blue: 0.0)
        for y in 0..<side {
            for x in 0..<side {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5,
                    let rgb = color.usingColorSpace(.deviceRGB)
                else { continue }
                let (red, green, blue) = (Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
                total = (total.weight + 1, total.red + red, total.green + green, total.blue + blue)
                let saturation = Double(rgb.saturationComponent)
                let brightness = Double(rgb.brightnessComponent)
                guard saturation > 0.25, brightness > 0.2 else { continue }
                let weight = saturation * saturation * brightness
                let bin = min(Int(Double(rgb.hueComponent) * 12), 11)
                bins[bin].weight += weight
                bins[bin].red += red * weight
                bins[bin].green += green * weight
                bins[bin].blue += blue * weight
            }
        }
        guard total.weight > 0 else { return nil }
        if let top = bins.max(by: { $0.weight < $1.weight }), top.weight > 8 {
            return (top.red / top.weight, top.green / top.weight, top.blue / top.weight)
        }
        return (total.red / total.weight, total.green / total.weight, total.blue / total.weight)
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let images = NSCache<NSString, NSImage>()

    init() {
        images.countLimit = 300
    }

    func cached(_ key: String) -> NSImage? {
        images.object(forKey: key as NSString)
    }

    func thumbnail(for clip: Clip, store: ClipStore) async -> NSImage? {
        guard let url = store.thumbnailURL(for: clip) else { return nil }
        if let image = cached(clip.uuid) { return image }
        let image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        if let image { images.setObject(image, forKey: clip.uuid as NSString) }
        return image
    }

    func icon(for clip: Clip, store: ClipStore) async -> NSImage? {
        guard let url = store.iconURL(for: clip) else { return nil }
        let key = "icon:" + clip.uuid
        if let image = cached(key) { return image }
        let image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        if let image { images.setObject(image, forKey: key as NSString) }
        return image
    }

    func fileThumbnail(path: String) async -> NSImage? {
        let key = "file:" + path
        if let image = cached(key) { return image }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path), size: CGSize(width: 360, height: 360), scale: 2,
            representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.nsImage
        images.setObject(image, forKey: key as NSString)
        return image
    }
}

enum ClipFormat {
    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func relativeTime(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "Just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    static func displayHost(of clip: Clip) -> String {
        guard let url = clip.preview.flatMap(ClipClassifier.linkURL(from:)) else { return "" }
        if url.scheme?.lowercased() == "mailto" { return url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
        let host = url.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func footer(for clip: Clip) -> String {
        switch clip.kind {
        case .text where clip.preview == nil, .code where clip.preview == nil:
            return byteCount(clip.byteSize)
        case .text, .code:
            let count = clip.textLength.formatted()
            return clip.textLength == 1 ? "1 character" : "\(count) characters"
        case .link:
            return clip.linkTitle == nil ? "" : displayHost(of: clip)
        case .image:
            guard let width = clip.pixelWidth, let height = clip.pixelHeight else { return byteCount(clip.byteSize) }
            return "\(width) × \(height), \(byteCount(clip.byteSize))"
        case .file:
            return clip.itemCount == 1 ? "1 file" : "\(clip.itemCount) files"
        case .color:
            return clip.preview.flatMap(ClipColor.parse)?.hex ?? "Color"
        }
    }
}

enum SearchHighlighter {
    private static let highlight = Color(red: 0.40, green: 0.95, blue: 0.86).opacity(0.6)

    static func tokens(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func apply(to attributed: inout AttributedString, query: String) {
        for token in tokens(in: query) {
            var start = attributed.startIndex
            while start < attributed.endIndex,
                let range = attributed[start...].range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) {
                attributed[range].backgroundColor = highlight
                start = range.upperBound
            }
        }
    }

    /// When the first match sits below what a card can show, starts the preview just before it.
    static func excerpt(of text: String, query: String) -> String {
        guard let token = tokens(in: query).first,
            let match = text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]),
            text.distance(from: text.startIndex, to: match.lowerBound) > 160
        else { return text }
        let start = text.index(match.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        return "…" + text[start...]
    }
}

@MainActor
enum CodeStyler {
    private static var cache: [String: AttributedString] = [:]

    private static let plain = Color(red: 0.89, green: 0.93, blue: 0.95)
    private static let keyword = Color(red: 0.76, green: 0.65, blue: 1.0)
    private static let string = Color(red: 0.53, green: 0.94, blue: 0.78)
    private static let number = Color(red: 1.0, green: 0.70, blue: 0.50)
    private static let type = Color(red: 0.49, green: 0.80, blue: 1.0)
    private static let comment = Color(red: 0.43, green: 0.54, blue: 0.59)

    // Later rules win, so strings and comments override anything that looks like a keyword inside them.
    private static let rules: [(NSRegularExpression, Color)] = [
        (#"\b[A-Z][A-Za-z0-9_]+\b"#, type),
        (#"\b(func|def|fn|class|struct|enum|interface|impl|trait|protocol|extension|import|from|export|const|let|var|val|return|if|else|elif|for|while|switch|case|break|continue|public|private|protected|static|async|await|try|catch|throw|throws|new|self|this|true|false|nil|null|None|True|False|SELECT|FROM|WHERE|INSERT|INTO|UPDATE|SET|DELETE|CREATE|TABLE|JOIN|ON|AND|OR|NOT)\b"#, keyword),
        (#"\b\d+(\.\d+)?\b"#, number),
        (#""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"#, string),
        (#"(//|#(?!include)).*$"#, comment),
    ].compactMap { pattern, color in
        (try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)).map { ($0, color) }
    }

    static func styled(_ clip: Clip) -> AttributedString {
        if let hit = cache[clip.uuid] { return hit }
        if cache.count > 200 { cache.removeAll() }
        let text = String((clip.preview ?? "").prefix(900))
        var attributed = AttributedString(text)
        attributed.foregroundColor = plain
        let whole = NSRange(text.startIndex..., in: text)
        for (expression, color) in rules {
            for match in expression.matches(in: text, range: whole) {
                guard let stringRange = Range(match.range, in: text),
                    let range = Range(stringRange, in: attributed)
                else { continue }
                attributed[range].foregroundColor = color
            }
        }
        cache[clip.uuid] = attributed
        return attributed
    }
}

/// A small clipboard for the menu bar, drawn so macOS can tint it like any other template image.
enum StatusGlyph {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let board = NSBezierPath(roundedRect: NSRect(x: 3.4, y: 1.6, width: 11.2, height: 13.4), xRadius: 2.8, yRadius: 2.8)
            board.lineWidth = 1.6
            board.stroke()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 13.2, width: 6, height: 3.6), xRadius: 1.5, yRadius: 1.5).fill()
            for (y, width) in [(9.6, 5.8), (6.8, 5.8), (4.0, 3.6)] as [(CGFloat, CGFloat)] {
                NSBezierPath(roundedRect: NSRect(x: 6.1, y: y, width: width, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Clipboard"
        return image
    }
}
