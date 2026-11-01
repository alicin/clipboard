import Foundation

/// What a web page says about itself in its head.
public struct LinkPage: Sendable, Equatable {
    public struct Icon: Sendable, Equatable {
        public let url: URL
        public let pixels: Int
    }

    public let title: String?
    public let imageURLs: [URL]
    /// Largest first, ending with the places browsers look when a page names none.
    public let icons: [Icon]
    public let manifestURL: URL?

    private static let tag = try! NSRegularExpression(pattern: #"<(meta|link)\b[^>]*>"#, options: .caseInsensitive)
    private static let attribute = try! NSRegularExpression(pattern: #"([a-zA-Z_:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    private static let titleTag = try! NSRegularExpression(pattern: #"<title[^>]*>(.*?)</title>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let imageProperties = ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"]

    public init(html: String, baseURL: URL) {
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html
        let range = NSRange(head.startIndex..., in: head)
        var properties: [String: String] = [:]
        var icons: [Icon] = []
        var manifest: URL?

        for match in Self.tag.matches(in: head, range: range) {
            guard let tagRange = Range(match.range, in: head) else { continue }
            let fields = Self.attributes(of: String(head[tagRange]))
            if head[tagRange].lowercased().hasPrefix("<meta") {
                if let key = (fields["property"] ?? fields["name"])?.lowercased(), let content = fields["content"], properties[key] == nil {
                    properties[key] = content
                }
                continue
            }
            guard let href = fields["href"], let url = Self.resolve(href, against: baseURL) else { continue }
            let rel = Set((fields["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            if rel.contains("manifest") {
                manifest = url
            } else if let fallback = Self.fallbackPixels(for: rel), !Self.isVector(url, type: fields["type"]) {
                icons.append(Icon(url: url, pixels: Self.largestSize(in: fields["sizes"]) ?? fallback))
            }
        }

        for (path, pixels) in [("/apple-touch-icon.png", 180), ("/favicon.ico", 16)] {
            if let url = URL(string: path, relativeTo: baseURL)?.absoluteURL, !icons.contains(where: { $0.url == url }) {
                icons.append(Icon(url: url, pixels: pixels))
            }
        }

        let titleText = Self.titleTag.firstMatch(in: head, range: range)
            .flatMap { Range($0.range(at: 1), in: head) }
            .map { String(head[$0]) }
        let named = properties["og:title"] ?? properties["twitter:title"] ?? titleText
        let cleaned = named.map { Self.decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        title = cleaned?.isEmpty == false ? cleaned : nil
        imageURLs = Self.imageProperties.compactMap { properties[$0] }.compactMap { Self.resolve($0, against: baseURL) }
        self.icons = Self.largestFirst(icons)
        manifestURL = manifest
    }

    /// The icons listed in a web app manifest, which is often the only place a site offers a large one.
    public static func icons(fromManifest data: Data, at manifestURL: URL) -> [Icon] {
        struct Manifest: Decodable {
            struct Entry: Decodable {
                let src: String
                let sizes: String?
                let type: String?
            }
            let icons: [Entry]?
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        let icons = (manifest.icons ?? []).compactMap { entry -> Icon? in
            guard let url = resolve(entry.src, against: manifestURL), !isVector(url, type: entry.type) else { return nil }
            return Icon(url: url, pixels: largestSize(in: entry.sizes) ?? 0)
        }
        return largestFirst(icons)
    }

    public static func largestFirst(_ icons: [Icon]) -> [Icon] {
        icons.enumerated().sorted { ($0.element.pixels, $1.offset) > ($1.element.pixels, $0.offset) }.map(\.element)
    }

    private static func attributes(of tag: String) -> [String: String] {
        var fields: [String: String] = [:]
        for match in attribute.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let name = Range(match.range(at: 1), in: tag) else { continue }
            let value = (2...4).lazy.compactMap { Range(match.range(at: $0), in: tag) }.first.map { String(tag[$0]) } ?? ""
            fields[tag[name].lowercased()] = decodeEntities(value)
        }
        return fields
    }

    private static func fallbackPixels(for rel: Set<String>) -> Int? {
        if rel.contains("fluid-icon") { return 512 }
        if rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed") { return 180 }
        return rel.contains("icon") ? 32 : nil
    }

    // ImageIO can't draw SVG, which is what many sites offer as their sharpest icon.
    private static func isVector(_ url: URL, type: String?) -> Bool {
        url.pathExtension.lowercased() == "svg" || type?.lowercased().contains("svg") == true
    }

    private static func largestSize(in sizes: String?) -> Int? {
        sizes?.lowercased().split(whereSeparator: \.isWhitespace)
            .compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }
            .max()
    }

    private static func resolve(_ reference: String, against base: URL) -> URL? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
            let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

public enum LinkPreviewPolicy {
    private static let singleUseQueryNames: Set<String> = [
        "auth", "code", "key", "magic", "nonce", "otp", "password", "secret", "session", "sig", "signature", "ticket",
    ]
    private static let singleUsePathWords = [
        "activate", "callback", "confirm", "invite", "login", "logout", "magic", "oauth", "password", "reset", "signin",
        "sign-in", "sso", "unsubscribe", "verify",
    ]

    /// A preview loads the page, so it mustn't reach hosts inside the user's network, or use up a link that only works
    /// once, like a password reset or a magic login, before the user gets to it.
    public static func allowsFetching(_ url: URL) -> Bool {
        isPublicWebURL(url) && !looksSingleUse(url)
    }

    private static func isPublicWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = url.host?.lowercased(), host.contains(".")
        else { return false }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".localhost") { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return true }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254), (172, 16...31): return false
        default: return true
        }
    }

    private static func looksSingleUse(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if singleUsePathWords.contains(where: path.contains) { return true }
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
        return names.contains { singleUseQueryNames.contains($0) || $0.contains("token") }
    }
}
