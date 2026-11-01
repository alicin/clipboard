import Foundation
import Testing

@testable import ClipboardCore

@Suite struct LinkPageTests {
    private let base = URL(string: "https://example.com/blog/post")!

    @Test func readsTitleAndImageFromOpenGraph() {
        let page = LinkPage(html: """
            <html><head>
            <title>Fallback title</title>
            <meta property="og:title" content="Kittens &amp; Friends">
            <meta content="/images/card.png" property="og:image">
            <meta name="twitter:image" content="https://cdn.example.com/twitter.png">
            </head><body><meta property="og:image" content="/not-this-one.png"></body></html>
            """, baseURL: base)
        #expect(page.title == "Kittens & Friends")
        #expect(page.imageURLs.map(\.absoluteString) == ["https://example.com/images/card.png", "https://cdn.example.com/twitter.png"])
    }

    @Test func fallsBackToTheTitleTag() {
        let page = LinkPage(html: "<head><TITLE>\n  Just a title\n</TITLE></head>", baseURL: base)
        #expect(page.title == "Just a title")
        #expect(page.imageURLs.isEmpty)
    }

    @Test func ranksIconsLargestFirst() {
        let page = LinkPage(html: """
            <head>
            <link rel="shortcut icon" href="/favicon.ico">
            <link rel='icon' sizes='32x32 96x96' href='/icon-96.png'>
            <link rel=apple-touch-icon href=/touch.png>
            <link rel="fluid-icon" href="https://example.com/fluid.png">
            <link rel="stylesheet" href="/style.css">
            </head>
            """, baseURL: base)
        #expect(page.icons.map(\.url.path) == ["/fluid.png", "/touch.png", "/apple-touch-icon.png", "/icon-96.png", "/favicon.ico"])
        #expect(page.icons.map(\.pixels) == [512, 180, 180, 96, 32])
    }

    @Test func skipsVectorIconsBecauseTheyCantBeDrawn() {
        let page = LinkPage(html: """
            <head>
            <link rel="icon" href="/logo.svg" sizes="any">
            <link rel="icon" href="/logo" type="image/svg+xml">
            <link rel="mask-icon" href="/mask.png">
            </head>
            """, baseURL: base)
        #expect(page.icons.map(\.url.path) == ["/apple-touch-icon.png", "/favicon.ico"])
    }

    @Test func aPageWithNoHeadStillOffersTheUsualPlaces() {
        let page = LinkPage(html: "not really html", baseURL: base)
        #expect(page.title == nil)
        #expect(page.icons.map(\.url.absoluteString) == ["https://example.com/apple-touch-icon.png", "https://example.com/favicon.ico"])
    }

    @Test func findsTheManifestAndReadsItsIcons() throws {
        let page = LinkPage(html: #"<head><link rel="manifest" href="/app.webmanifest"></head>"#, baseURL: base)
        let manifestURL = try #require(page.manifestURL)
        #expect(manifestURL.absoluteString == "https://example.com/app.webmanifest")
        let manifest = #"{"name":"x","icons":[{"src":"small.png","sizes":"48x48"},{"src":"/big.png","sizes":"512x512"},{"src":"v.svg","sizes":"any"}]}"#
        let icons = LinkPage.icons(fromManifest: Data(manifest.utf8), at: manifestURL)
        #expect(icons.map(\.url.path) == ["/big.png", "/small.png"])
        #expect(LinkPage.icons(fromManifest: Data("nope".utf8), at: manifestURL).isEmpty)
    }

    @Test(arguments: [
        "https://www.facebook.com/", "https://github.com/alicin/clipboard", "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://en.wikipedia.org/wiki/Cat", "https://example.com/article?id=12&utm_source=mail", "http://8.8.8.8/",
    ])
    func ordinaryLinksGetPreviews(link: String) throws {
        #expect(LinkPreviewPolicy.allowsFetching(try #require(URL(string: link))))
    }

    @Test(arguments: [
        "http://192.168.1.10/admin", "http://10.0.0.1/", "http://172.20.1.1/", "http://127.0.0.1:8080/", "https://printer.local/",
        "https://wiki.internal/home", "http://localhost/", "ftp://example.com/file",
    ])
    func privateAddressesAreNeverVisited(link: String) throws {
        #expect(!LinkPreviewPolicy.allowsFetching(try #require(URL(string: link))))
    }

    @Test(arguments: [
        "https://example.com/reset-password/abc123", "https://example.com/verify?email=a@b.c", "https://example.com/unsubscribe/42",
        "https://example.com/welcome?token=abc", "https://example.com/go?access_token=abc", "https://example.com/?code=abc123",
        "https://accounts.example.com/oauth/authorize?client_id=1", "https://example.com/login", "https://example.com/a?signature=abc",
    ])
    func singleUseLinksAreNeverVisited(link: String) throws {
        #expect(!LinkPreviewPolicy.allowsFetching(try #require(URL(string: link))))
    }
}

@Suite struct LinkMetadataStoreTests {
    @Test func savesTheIconAndKeepsItOnRecapture() throws {
        let temp = try TemporaryStore()
        let saved = try temp.add("https://example.com/")
        #expect(!saved.hasIcon)
        #expect(temp.store.iconURL(for: saved) == nil)

        try temp.store.setLinkMetadata(title: "Example", thumbnail: nil, icon: samplePNG(), clipID: saved.id)
        let fetched = try #require(try temp.store.clip(id: saved.id))
        #expect(fetched.hasIcon)
        #expect(fetched.linkTitle == "Example")
        let icon = try #require(temp.store.iconURL(for: fetched))
        #expect(FileManager.default.fileExists(atPath: icon.path))

        let again = try temp.add("https://example.com/")
        #expect(again.uuid != saved.uuid)
        #expect(again.hasIcon)
        let moved = try #require(temp.store.iconURL(for: again))
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }

    @Test func aFailedFetchKeepsWhatItAlreadyHas() throws {
        let temp = try TemporaryStore()
        let saved = try temp.add("https://example.com/")
        try temp.store.setLinkMetadata(title: "Example", thumbnail: nil, clipID: saved.id)
        try temp.store.setLinkMetadata(title: nil, thumbnail: nil, clipID: saved.id)
        #expect(try temp.store.clip(id: saved.id)?.linkTitle == "Example")
    }

    @Test func listsRecentLinksThatHaventBeenTriedNewestFirst() throws {
        let temp = try TemporaryStore()
        let now = Date()
        try temp.add("https://old.example.com/", at: now.addingTimeInterval(-30 * 86400))
        let tried = try temp.add("https://tried.example.com/", at: now.addingTimeInterval(-300))
        let first = try temp.add("https://first.example.com/", at: now.addingTimeInterval(-200))
        let second = try temp.add("https://second.example.com/", at: now.addingTimeInterval(-100))
        try temp.add("Not a link", at: now)
        try temp.add("https://example.com/?key=ghp_abcdefghijklmnopqrstuvwxyz0123456789", at: now, secrets: .hide)
        try temp.store.setLinkMetadata(title: nil, thumbnail: nil, clipID: tried.id)

        let waiting = try temp.store.linksMissingPreview(since: now.addingTimeInterval(-7 * 86400))
        #expect(waiting.map(\.id) == [second.id, first.id])
    }

    @Test func aHiddenLinkDoesNotShowItsIcon() throws {
        let temp = try TemporaryStore()
        let saved = try temp.add("https://example.com/?key=ghp_abcdefghijklmnopqrstuvwxyz0123456789", secrets: .show)
        try temp.store.setLinkMetadata(title: nil, thumbnail: nil, icon: samplePNG(), clipID: saved.id)
        #expect(try temp.store.clip(id: saved.id)?.hasIcon == false)
        temp.store.hidesSecrets = false
        #expect(try temp.store.clip(id: saved.id)?.hasIcon == true)
    }

    @Test func pullsTheLargestPictureOutOfAnIcoStyleFile() throws {
        let icon = try #require(Thumbnailer.icon(from: samplePNG(width: 300, height: 300), maxPixels: 256))
        #expect(icon.width == 256)
        let small = try #require(Thumbnailer.icon(from: samplePNG(width: 32, height: 32), maxPixels: 256))
        #expect(small.width == 32)
        #expect(Thumbnailer.icon(from: Data("not an image".utf8), maxPixels: 256) == nil)
    }

    @Test func upgradingKeepsSavedLinks() throws {
        let temp = try TemporaryStore()
        let saved = try temp.add("https://example.com/")
        let database = try Database(path: temp.directory.appendingPathComponent("history.sqlite").path, readOnly: false)
        try database.script("ALTER TABLE clips DROP COLUMN has_icon; ALTER TABLE clips DROP COLUMN link_checked; ALTER TABLE clips DROP COLUMN updated_at; DROP TABLE sync_objects; DROP TABLE sync_deletions; PRAGMA user_version = 2")

        let upgraded = try ClipStore(directory: temp.directory)
        #expect(try upgraded.clip(id: saved.id)?.hasIcon == false)
        #expect(try upgraded.linksMissingPreview(since: .distantPast).map(\.id) == [saved.id])
    }
}
