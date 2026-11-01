#if DEBUG
import AppKit
import ClipboardCore
import CoreGraphics
import Vision

/// The kittens live outside the app's sources, so they never reach a normal build.
@MainActor
enum DemoAssets {
    private static let root = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["CLIPBOARD_DEMO_ASSETS"] ?? "demo-assets", isDirectory: true)

    static func photoURL(_ name: String) -> URL { root.appendingPathComponent("kittens/\(name).jpg") }
    static func photoData(_ name: String) -> Data { (try? Data(contentsOf: photoURL(name))) ?? Data() }
    static func photo(_ name: String) -> NSImage { NSImage(contentsOf: photoURL(name)) ?? NSImage() }
}

/// Invented sample clips, so the video shows a believable history without using anyone's real clipboard.
@MainActor
enum DemoSeed {
    private static func text(_ text: String) -> Representation {
        Representation(uti: "public.utf8-plain-text", data: Data(text.utf8))
    }

    static func capture(_ reps: [[Representation]], app: String, name: String, store: ClipStore, minutesAgo: Double) -> Clip? {
        guard
            case .clip(let draft) = ClipBuilder.build(
                items: reps, source: ClipSource(bundleID: app, name: name), skipSecrets: true),
            let result = try? store.capture(draft, at: Date().addingTimeInterval(-minutesAgo * 60))
        else { return nil }
        return result.clip
    }

    static func captureText(_ value: String, app: String, name: String, store: ClipStore, minutesAgo: Double = 0) -> Clip? {
        capture([[text(value)]], app: app, name: name, store: store, minutesAgo: minutesAgo)
    }

    private static func capturePhoto(_ name: String, store: ClipStore, minutesAgo: Double) -> Clip? {
        capture(
            [[Representation(uti: "public.jpeg", data: DemoAssets.photoData(name))]],
            app: "com.apple.Photos", name: "Photos", store: store, minutesAgo: minutesAgo)
    }

    private static func picture(width: Int, height: Int, draw: (CGSize) -> Void) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(CGSize(width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private static func drawText(_ string: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black) {
        (string as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }

    private static func receipt() -> Data {
        picture(width: 900, height: 1040) { size in
            NSColor(white: 0.97, alpha: 1).setFill()
            CGRect(origin: .zero, size: size).fill()
            drawText("Whisker & Co.", at: NSPoint(x: 90, y: 900), size: 66, weight: .bold)
            drawText("Pet supplies, 14 Harbour Street", at: NSPoint(x: 90, y: 850), size: 30, color: .darkGray)
            let rows = [("Catnip mouse", "$4.50"), ("Scratching post", "$24.00"), ("Kitten kibble", "$12.75")]
            for (index, row) in rows.enumerated() {
                let y = 720 - CGFloat(index) * 72
                drawText(row.0, at: NSPoint(x: 90, y: y), size: 38)
                drawText(row.1, at: NSPoint(x: 680, y: y), size: 38, weight: .medium)
            }
            NSColor.lightGray.setFill()
            CGRect(x: 90, y: 480, width: 720, height: 3).fill()
            drawText("Total", at: NSPoint(x: 90, y: 400), size: 52, weight: .bold)
            drawText("$41.25", at: NSPoint(x: 640, y: 400), size: 52, weight: .bold)
            drawText("Purrs and thanks, see you soon", at: NSPoint(x: 90, y: 280), size: 32, color: .darkGray)
        }
    }

    private static func makeVetRecords(at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor(srgbRed: 0.07, green: 0.84, blue: 0.75, alpha: 1).setFill()
        CGRect(x: 0, y: 650, width: 612, height: 142).fill()
        drawText("Vet Records", at: NSPoint(x: 48, y: 690), size: 48, weight: .bold, color: NSColor(srgbRed: 0, green: 0.19, blue: 0.18, alpha: 1))
        DemoAssets.photo("mochi").draw(in: CGRect(x: 48, y: 330, width: 280, height: 292))
        drawText("Mochi", at: NSPoint(x: 350, y: 580), size: 34, weight: .bold)
        for (index, line) in ["12 weeks old", "Vaccines up to date", "Very good kitten", "Bites the stethoscope"].enumerated() {
            drawText(line, at: NSPoint(x: 350, y: 540 - CGFloat(index) * 34), size: 20)
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
    }

    private static func recognize(_ data: Data) async -> String {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try? VNImageRequestHandler(data: data).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    /// Fills the store, oldest first, so the newest clips lead the strip.
    static func populate(store: ClipStore, folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let records = folder.appendingPathComponent("Mochi's Vet Records.pdf")
        makeVetRecords(at: records)
        let beansFile = folder.appendingPathComponent("Toe Beans.jpg")
        try? DemoAssets.photoData("beans").write(to: beansFile)

        func file(_ url: URL) -> [Representation] {
            [Representation(uti: "public.file-url", data: Data(url.absoluteString.utf8))]
        }

        _ = captureText("https://tinypaws.example/kitten-names", app: "com.google.Chrome", name: "Google Chrome", store: store, minutesAgo: 3000)
        _ = capturePhoto("ginger", store: store, minutesAgo: 2600)
        _ = captureText("for i in {1..9}; do say meow; done", app: "com.apple.Terminal", name: "Terminal", store: store, minutesAgo: 2200)
        _ = captureText("hsl(346, 100%, 85%)", app: "com.pixelmatorteam.pixelmator.x", name: "Pixelmator Pro", store: store, minutesAgo: 1900)
        _ = captureText(
            "Kitten shopping: wet food, scratching post, feather wand, one more feather wand",
            app: "com.apple.Notes", name: "Notes", store: store, minutesAgo: 1500)
        let sprout = capturePhoto("sprout", store: store, minutesAgo: 1200)
        let vet = captureText("vet@tinypaws.example", app: "com.apple.mail", name: "Mail", store: store, minutesAgo: 900)
        let profile = captureText(
            "{\n  \"name\": \"Mochi\",\n  \"age_weeks\": 12,\n  \"favorite_toy\": \"the cursor\",\n  \"naps_per_day\": 19\n}",
            app: "com.microsoft.VSCode", name: "Visual Studio Code", store: store, minutesAgo: 700)
        _ = capturePhoto("bunny", store: store, minutesAgo: 500)
        _ = captureText(
            "Mochi fell asleep in the laundry basket again. Nobody move.",
            app: "com.apple.MobileSMS", name: "Messages", store: store, minutesAgo: 400)
        let beans = capturePhoto("beans", store: store, minutesAgo: 300)
        _ = capture(
            [[text("Welcome home, Mochi"), Representation(uti: "public.html", data: Data("<h1>Welcome home, Mochi</h1>".utf8))]],
            app: "com.apple.TextEdit", name: "TextEdit", store: store, minutesAgo: 240)

        let receiptData = receipt()
        if let image = capture([[Representation(uti: "public.png", data: receiptData)]], app: "com.apple.Preview", name: "Preview", store: store, minutesAgo: 180) {
            let words = await recognize(receiptData)
            try? store.setOCRText(words, clipID: image.id)
        }
        _ = capture([file(beansFile)], app: "com.apple.finder", name: "Finder", store: store, minutesAgo: 150)
        _ = capture([file(records)], app: "com.apple.finder", name: "Finder", store: store, minutesAgo: 120)
        _ = captureText("#FFB3C1", app: "com.pixelmatorteam.pixelmator.x", name: "Pixelmator Pro", store: store, minutesAgo: 60)
        let code = captureText(
            "func pet(_ kitten: Kitten) -> Sound {\n    // Behind the ears. Never the belly.\n    kitten.happiness += 1\n    return kitten.isSleepy ? .purr : .meow\n}\n\npet(mochi)",
            app: "com.apple.dt.Xcode", name: "Xcode", store: store, minutesAgo: 30)
        let mochi = capturePhoto("mochi", store: store, minutesAgo: 12)
        if let link = captureText("https://tinypaws.example/first-week-home", app: "com.apple.Safari", name: "Safari", store: store, minutesAgo: 6) {
            try? store.setLinkMetadata(
                title: "How to welcome a new kitten", thumbnail: Thumbnailer.make(from: DemoAssets.photoData("pixel"), maxPixels: 720)?.png, clipID: link.id)
        }
        let message = captureText(
            "Can you send me the kitten pics before standup? The whole team has been asking, and honestly morale depends on it. Mochi in the tiny sweater first, then the one with the paw on the keyboard.",
            app: "com.tinyspeck.slackmacgap", name: "Slack", store: store, minutesAgo: 3)

        if let board = try? store.createPinboard(name: "Mochi", color: "sky") {
            for clip in [beans, vet, profile, sprout].compactMap({ $0 }) { try? store.pin(clipID: clip.id, pinboardID: board.id) }
        }
        let now = Date()
        for (clip, hoursAgo) in [(vet, 2.0), (vet, 20.0), (code, 5.0), (message, 1.0), (mochi, 3.0)] as [(Clip?, Double)] {
            if let clip { try? store.recordPaste(clipID: clip.id, targetBundleID: "com.apple.finder", at: now.addingTimeInterval(-hoursAgo * 3600)) }
        }
        // recordPaste moves a clip to the front, but these events only exist to feed Suggested.
        for (clip, minutes) in [(vet, 900.0), (code, 30.0), (message, 3.0), (mochi, 12.0)] as [(Clip?, Double)] {
            if let clip { try? store.setSortDateForDemo(clipID: clip.id, date: now.addingTimeInterval(-minutes * 60)) }
        }
    }
}
#endif
