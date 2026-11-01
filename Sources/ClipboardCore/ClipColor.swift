import Foundation

public struct ClipColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public var hex: String {
        let channels = [red, green, blue].map { String(format: "%02X", Int(($0 * 255).rounded())) }
        return "#" + channels.joined()
    }

    public var luminance: Double {
        0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private static let hexPattern = try! NSRegularExpression(
        pattern: "^(?:#|0x)([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$", options: .caseInsensitive)
    private static let functionPattern = try! NSRegularExpression(
        pattern: #"^(rgb|hsl)a?\(\s*([\d.]+)(deg|%)?[\s,]+([\d.]+)%?[\s,]+([\d.]+)%?(?:[\s,/]+([\d.]+)(%)?)?\s*\)$"#,
        options: .caseInsensitive)

    public static func parse(_ raw: String) -> ClipColor? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 48 else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        if let match = hexPattern.firstMatch(in: text, range: range),
            let digits = Range(match.range(at: 1), in: text).map({ String(text[$0]) }) {
            return parseHex(digits)
        }
        guard let match = functionPattern.firstMatch(in: text, range: range) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let function = group(1)?.lowercased(),
            let first = group(2).flatMap(Double.init),
            let second = group(4).flatMap(Double.init),
            let third = group(5).flatMap(Double.init)
        else { return nil }
        var alpha = group(6).flatMap(Double.init) ?? 1
        if group(7) != nil { alpha /= 100 }
        if function == "rgb" {
            guard [first, second, third].allSatisfy({ $0 <= 255 }), alpha <= 1 else { return nil }
            return ClipColor(red: first / 255, green: second / 255, blue: third / 255, alpha: alpha)
        }
        guard first <= 360, second <= 100, third <= 100, alpha <= 1 else { return nil }
        let rgb = hslToRGB(hue: first / 360, saturation: second / 100, lightness: third / 100)
        return ClipColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
    }

    private static func parseHex(_ digits: String) -> ClipColor? {
        var expanded = digits
        if digits.count <= 4 { expanded = digits.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        return ClipColor(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1)
    }

    private static func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> (Double, Double, Double) {
        guard saturation > 0 else { return (lightness, lightness, lightness) }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ offset: Double) -> Double {
            var t = hue + offset
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(1.0 / 3), channel(0), channel(-1.0 / 3))
    }
}
