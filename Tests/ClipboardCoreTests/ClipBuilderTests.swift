import AppKit
import Foundation
import Testing

@testable import ClipboardCore

func utf8Rep(_ text: String, type: String = "public.utf8-plain-text") -> Representation {
    Representation(uti: type, data: Data(text.utf8))
}

func samplePNG(width: Int = 20, height: Int = 10) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemRed.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func draft(from items: [[Representation]], secrets: SecretHandling = .skip, app: String? = "com.example.app") -> ClipDraft? {
    if case .clip(let draft) = ClipBuilder.build(
        items: items, source: ClipSource(bundleID: app, name: "Example"), secrets: secrets) {
        return draft
    }
    return nil
}

@Suite struct ClipBuilderTests {
    @Test func plainTextBecomesTextClip() throws {
        let clip = try #require(draft(from: [[utf8Rep("Hello there, friend.")]]))
        #expect(clip.kind == .text)
        #expect(clip.text == "Hello there, friend.")
        #expect(clip.byteSize == 20)
    }

    @Test func fileURLsWinOverTheirTextAndIcon() throws {
        let items = [
            [utf8Rep("file:///tmp/a%20b.txt", type: "public.file-url"), utf8Rep("a b.txt"), Representation(uti: "public.tiff", data: samplePNG())],
            [utf8Rep("file:///tmp/c.txt", type: "public.file-url")],
        ]
        let clip = try #require(draft(from: items))
        #expect(clip.kind == .file)
        #expect(clip.text == "/tmp/a b.txt\n/tmp/c.txt")
        #expect(clip.items.count == 2)
    }

    @Test func imageWithoutTextBecomesImageClip() throws {
        let png = samplePNG(width: 40, height: 30)
        let clip = try #require(draft(from: [[Representation(uti: "public.png", data: png)]]))
        #expect(clip.kind == .image)
        #expect(clip.pixelWidth == 40)
        #expect(clip.pixelHeight == 30)
        #expect(clip.thumbnail != nil)
    }

    @Test func copyImageFromBrowserStaysAnImage() throws {
        let items = [[
            Representation(uti: "public.tiff", data: samplePNG()),
            utf8Rep("https://example.com/cat.png", type: "public.url"),
            utf8Rep("https://example.com/cat.png"),
        ]]
        let clip = try #require(draft(from: items))
        #expect(clip.kind == .image)
    }

    @Test func spreadsheetCellWithPictureStaysText() throws {
        let items = [[utf8Rep("Revenue by quarter"), Representation(uti: "public.png", data: samplePNG())]]
        #expect(draft(from: items)?.kind == .text)
    }

    @Test func corruptImageWithNoTextFallsBackToOpaqueData() throws {
        let clip = try #require(draft(from: [[Representation(uti: "public.png", data: Data([1, 2, 3]))]]))
        #expect(clip.kind == .text)
        #expect(clip.text == nil)
    }

    @Test func htmlOnlyIsStrippedForSearch() throws {
        let clip = try #require(draft(from: [[utf8Rep("<p>Hello <b>big</b> &amp; bold world</p>", type: "public.html")]]))
        #expect(clip.text == "Hello big & bold world")
    }

    @Test func htmlAroundAnImageCopyIsNotText() throws {
        let items = [[
            utf8Rep("<img src=\"https://example.com/x.png\">", type: "public.html"),
            Representation(uti: "public.png", data: samplePNG()),
        ]]
        #expect(draft(from: items)?.kind == .image)
    }

    @Test func secretsAreSkippedOnlyWhenAsked() throws {
        let items = [[utf8Rep("token ghp_abcdefghijklmnopqrstuvwxyz0123456789")]]
        guard case .skippedSecret = ClipBuilder.build(items: items, source: ClipSource(bundleID: nil, name: nil), secrets: .skip) else {
            Issue.record("expected the secret to be skipped")
            return
        }
        #expect(try #require(draft(from: items, secrets: .hide)).isSecret)
        #expect(try #require(draft(from: items, secrets: .show)).isSecret)
    }

    @Test func ordinaryTextIsNotFlaggedAsASecret() throws {
        #expect(try #require(draft(from: [[utf8Rep("Just a note")]], secrets: .hide)).isSecret == false)
    }

    @Test func anImageWithASecretInItsLinkIsFlagged() throws {
        let items = [[
            utf8Rep("https://example.com/x.png?key=ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
            Representation(uti: "public.png", data: samplePNG()),
        ]]
        let clip = try #require(draft(from: items, secrets: .hide))
        #expect(clip.kind == .image)
        #expect(clip.isSecret)
    }

    @Test func whitespaceOnlyIsSkipped() {
        guard case .skippedEmpty = ClipBuilder.build(
            items: [[utf8Rep("   \n ")]], source: ClipSource(bundleID: nil, name: nil), secrets: .skip)
        else {
            Issue.record("expected whitespace to be skipped")
            return
        }
    }

    @Test func sameTextHashesEquallyAcrossFormats() throws {
        let plain = try #require(draft(from: [[utf8Rep("Same words here")]]))
        let rich = try #require(draft(from: [[utf8Rep("Same words here"), utf8Rep("<b>Same words here</b>", type: "public.html")]]))
        #expect(plain.hash == rich.hash)
    }

    @Test func concealedAndTransientMarkersAreIgnored() {
        #expect(PasteboardMarkers.shouldIgnore(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(PasteboardMarkers.shouldIgnore(types: ["org.nspasteboard.TransientType"]))
        #expect(PasteboardMarkers.shouldIgnore(types: [PasteboardMarkers.restored]))
        #expect(!PasteboardMarkers.shouldIgnore(types: ["public.utf8-plain-text"]))
    }

    @Test func markerTypesAreNotStored() throws {
        let clip = try #require(draft(from: [[utf8Rep("Hello"), utf8Rep("com.example", type: PasteboardMarkers.source)]]))
        #expect(clip.items[0].map(\.uti) == ["public.utf8-plain-text"])
    }
}
