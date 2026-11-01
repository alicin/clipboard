// Draws the README's title, install button and key caps. GitHub fixes <kbd> text at 11px and strips custom CSS, so bigger
// keys have to be images. They're dark like the key overlay in the demo, which reads on both of GitHub's themes.
//     swiftc -o /tmp/make-readme-art scripts/make-readme-art.swift && /tmp/make-readme-art demo-assets/readme
import AppKit
import SwiftUI

@MainActor
func save<V: View>(_ view: V, to path: String, scale: CGFloat = 2) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let image = renderer.cgImage else { fatalError("Nothing rendered for \(path)") }
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

struct Wordmark: View {
    var body: some View {
        Text("Clipboard")
            .font(.system(size: 92, weight: .heavy, design: .rounded))
            .tracking(-1.5)
            .foregroundStyle(
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.76, blue: 0.67), Color(red: 0.07, green: 0.58, blue: 0.90)],
                    startPoint: .leading, endPoint: .trailing)
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
    }
}

struct InstallButton: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 14, weight: .bold))
            Text("Build and install").font(.system(size: 15.5, weight: .bold, design: .rounded))
        }
        .foregroundStyle(Color(red: 0.02, green: 0.20, blue: 0.18))
        .padding(.horizontal, 20)
        .frame(height: 42)
        .background(
            LinearGradient(
                colors: [Color(red: 0.40, green: 0.95, blue: 0.86), Color(red: 0.07, green: 0.84, blue: 0.75)],
                startPoint: .top, endPoint: .bottom),
            in: Capsule()
        )
        .overlay { Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
    }
}

struct KeyCap: View {
    let label: String

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 7, style: .continuous) }

    var body: some View {
        Text(label)
            .font(.system(size: label.count > 2 ? 13 : 15.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, label.count > 2 ? 11 : 0)
            .frame(minWidth: 30, minHeight: 28)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.25, green: 0.28, blue: 0.32), Color(red: 0.15, green: 0.17, blue: 0.20)],
                    startPoint: .top, endPoint: .bottom),
                in: shape
            )
            .overlay { shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.75) }
            // The lip along the bottom edge is what makes it read as a key rather than a badge.
            .padding(.bottom, 2)
            .background(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.08, blue: 0.10))
                    .frame(height: 16)
            }
    }
}

let keys = [
    "shift": "⇧", "cmd": "⌘", "left": "←", "right": "→", "return": "↩\u{FE0E}", "delete": "⌫", "tab": "⇥", "esc": "⎋",
    "space": "Space", "type": "Type", "v": "V", "c": "C", "1": "1", "9": "9",
]

MainActor.assumeIsolated {
    let folder = CommandLine.arguments[1]
    save(Wordmark(), to: folder + "/wordmark.png")
    save(InstallButton(), to: folder + "/button-install.png")
    try! FileManager.default.createDirectory(atPath: folder + "/keys", withIntermediateDirectories: true)
    for (name, label) in keys {
        save(KeyCap(label: label), to: "\(folder)/keys/\(name).png", scale: 3)
    }
}
