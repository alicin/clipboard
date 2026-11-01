// Helper for scripts/ui_test.py: sends commands to a debug build, fills the private test pasteboard, lists windows.
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())

func send(stateFile: String, command: String) {
    let sequence = String(Int(Date().timeIntervalSince1970 * 1000))
    DistributedNotificationCenter.default().postNotificationName(
        .init("com.bunniesinc.clipboard.test"), object: sequence + " " + command, userInfo: nil, deliverImmediately: true)
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline {
        if let data = FileManager.default.contents(atPath: stateFile),
            let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            state["sequence"] as? String == sequence {
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        }
        usleep(40_000)
    }
    fputs("timed out waiting for the app to answer: \(command)\n", stderr)
    exit(1)
}

func write(_ items: [NSPasteboardItem]) {
    let pasteboard = NSPasteboard(name: .init(ProcessInfo.processInfo.environment["PB_NAME"]!))
    pasteboard.clearContents()
    pasteboard.writeObjects(items)
}

func item(_ text: String) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    return item
}

func makeImage(path: String, text: String) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 520, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 900, height: 520).fill()
    (text as NSString).draw(
        at: NSPoint(x: 50, y: 220),
        withAttributes: [.font: NSFont.systemFont(ofSize: 64, weight: .semibold), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

switch arguments[0] {
case "send":
    send(stateFile: arguments[1], command: arguments.dropFirst(2).joined(separator: " "))
case "text":
    write([item(arguments[1])])
case "rich":
    let rich = item(arguments[1])
    rich.setString("<b>\(arguments[1])</b>", forType: .html)
    write([rich])
case "concealed":
    let concealed = item(arguments[1])
    concealed.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    write([concealed])
case "from-app":
    let marked = item(arguments[2])
    marked.setString(arguments[1], forType: .init("org.nspasteboard.source"))
    write([marked])
case "image":
    let image = NSPasteboardItem()
    image.setData(try Data(contentsOf: URL(fileURLWithPath: arguments[1])), forType: .png)
    write([image])
case "make-image":
    try makeImage(path: arguments[1], text: arguments[2])
case "files":
    write(arguments.dropFirst().map { path in
        let file = NSPasteboardItem()
        file.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        return file
    })
case "corner-alpha":
    let rep = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: arguments[1])))!
    let (width, height) = (rep.pixelsWide - 1, rep.pixelsHigh - 1)
    print([(0, 0), (width, 0), (0, height), (width, height)].map { "\(rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1)" }.joined(separator: " "))
case "windows":
    let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in list where window[kCGWindowOwnerName as String] as? String == "Clipboard" && window[kCGWindowIsOnscreen as String] as? Bool == true {
        let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print(window[kCGWindowNumber as String] ?? 0, Int(bounds["Width"] ?? 0), Int(bounds["Height"] ?? 0))
    }
default:
    fputs("unknown command\n", stderr)
    exit(2)
}
