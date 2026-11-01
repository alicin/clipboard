import Foundation

public enum ClipKind: String, CaseIterable, Sendable, Codable {
    case text, link, image, file, color, code

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .image: "Image"
        case .file: "File"
        case .color: "Color"
        case .code: "Code"
        }
    }
}

public struct Representation: Sendable, Hashable {
    public let uti: String
    public let data: Data

    public init(uti: String, data: Data) {
        self.uti = uti
        self.data = data
    }
}

public struct ClipSource: Sendable, Hashable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}

public struct Clip: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let uuid: String
    public let kind: ClipKind
    public let title: String?
    public let preview: String?
    public let textLength: Int
    public let source: ClipSource
    public let createdAt: Date
    public let sortedAt: Date
    public let byteSize: Int64
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let itemCount: Int
    public let pasteCount: Int
    public let linkTitle: String?
    public let hasThumbnail: Bool
    public let pinboardIDs: [Int64]
    public let isSecret: Bool
    /// A secret currently shown as dots. `preview` holds only `hiddenPreview`, while pasting still gives the real text.
    public let isHidden: Bool

    public static let hiddenPreview = String(repeating: "•", count: 12)
}

public struct Pinboard: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let color: String
    public let position: Int
}

public struct ClipQuery: Sendable {
    public var text: String
    public var kind: ClipKind?
    public var pinboardID: Int64?
    public var pinnedOnly: Bool
    public var excludesSecrets: Bool
    public var limit: Int
    public var offset: Int

    public init(
        text: String = "",
        kind: ClipKind? = nil,
        pinboardID: Int64? = nil,
        pinnedOnly: Bool = false,
        excludesSecrets: Bool = false,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.text = text
        self.kind = kind
        self.pinboardID = pinboardID
        self.pinnedOnly = pinnedOnly
        self.excludesSecrets = excludesSecrets
        self.limit = limit
        self.offset = offset
    }
}

public struct CaptureResult: Sendable {
    public let clip: Clip
    public let isNew: Bool
}

public struct StoreStats: Sendable, Equatable {
    public let clipCount: Int
    public let totalBytes: Int64
}

public struct KindBreakdown: Sendable, Equatable, Identifiable {
    public let kind: ClipKind
    public let count: Int
    public let bytes: Int64

    public var id: ClipKind { kind }
}

public enum AIAccess: String, CaseIterable, Sendable {
    case off, pinboards, everything
}

public enum SecretHandling: String, CaseIterable, Sendable {
    case skip, hide, show
}
