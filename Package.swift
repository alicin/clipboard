// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clipboard",
    platforms: [.macOS("15.4")],
    targets: [
        .target(name: "ClipboardCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Clipboard", dependencies: ["ClipboardCore"]),
        .executableTarget(name: "clipboard-mcp", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"]),
    ],
    swiftLanguageModes: [.v5]
)
