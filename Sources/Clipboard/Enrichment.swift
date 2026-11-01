import AppKit
import LinkPresentation
import ClipboardCore
import UniformTypeIdentifiers
import Vision

@MainActor
final class ClipEnricher {
    private let store: ClipStore
    private let preferences: Preferences
    private var isFetchingLink = false

    init(store: ClipStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    func process(_ result: CaptureResult) {
        switch result.clip.kind {
        case .image where result.isNew && !result.clip.isSecret: recognizeText(in: result.clip)
        case .link: fetchMissingLinkPreviews()
        default: break
        }
    }

    private func recognizeText(in clip: Clip) {
        let store = store
        Task.detached(priority: .utility) {
            guard let payload = try? store.payload(for: clip),
                let image = payload.joined().first(where: { $0.uti.hasPrefix("public.") && NSImage(data: $0.data) != nil })
            else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(data: image.data).perform([request])
            } catch {
                return
            }
            let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
            guard !lines.isEmpty else { return }
            try? store.setOCRText(lines.joined(separator: "\n"), clipID: clip.id)
            await MainActor.run { NotificationCenter.default.post(name: .clipsChanged, object: nil) }
        }
    }

    /// One at a time, newest first, because each one loads a page. The week's limit keeps turning previews on from
    /// visiting every link in a long history.
    func fetchMissingLinkPreviews() {
        guard preferences.linkPreviews, !isFetchingLink,
            let clip = try? store.linksMissingPreview(since: Date().addingTimeInterval(-7 * 86400), limit: 1).first
        else { return }
        isFetchingLink = true
        let store = store
        Task {
            var preview = LinkPreview()
            if let url = clip.preview.flatMap(ClipClassifier.linkURL(from:)), LinkPreviewPolicy.allowsFetching(url) {
                do {
                    preview = try await LinkPreview.fetch(url)
                } catch {
                    // Offline right now, so this link stays on the list for the next copy or launch.
                    isFetchingLink = false
                    return
                }
            }
            try? store.setLinkMetadata(title: preview.title, thumbnail: preview.image, icon: preview.icon, clipID: clip.id)
            NotificationCenter.default.post(name: .clipsChanged, object: nil)
            isFetchingLink = false
            fetchMissingLinkPreviews()
        }
    }
}

private struct LinkPreview {
    var title: String?
    var image: Data?
    var icon: Data?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        // Plenty of sites leave their preview tags out for anything that doesn't look like a browser.
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        ]
        return URLSession(configuration: configuration)
    }()

    private static let iconPixels = 256
    private static let sharpIconPixels = 128
    private static let imagePixels = 720

    /// LinkPresentation runs the page's scripts, which some sites need to show anything, but its icon is often small and
    /// it misses some preview images. Reading the page's own tags covers both.
    @MainActor static func fetch(_ url: URL) async throws -> LinkPreview {
        async let page = LinkPreview.page(at: url)
        let system = await systemMetadata(for: url)
        let found = try await page
        var preview = LinkPreview(title: system.title ?? found?.title)
        preview.image = await image(from: system.image, orAnyOf: found?.imageURLs ?? [])
        preview.icon = await icon(from: found, fallback: system.icon)
        return preview
    }

    private static func page(at url: URL) async throws -> LinkPage? {
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard response.mimeType?.contains("html") == true else { return nil }
            var data = Data()
            // The head is all that matters, and a link can point at something enormous.
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 512_000 { break }
            }
            return LinkPage(html: String(decoding: data, as: UTF8.self), baseURL: response.url ?? url)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw error
        } catch {
            return nil
        }
    }

    @MainActor private static func systemMetadata(for url: URL) async -> (title: String?, image: Data?, icon: Data?) {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        let metadata = await withCheckedContinuation { (continuation: CheckedContinuation<LPLinkMetadata?, Never>) in
            provider.startFetchingMetadata(for: url) { metadata, _ in
                continuation.resume(returning: metadata)
            }
        }
        async let image = data(from: metadata?.imageProvider)
        async let icon = data(from: metadata?.iconProvider)
        return (metadata?.title, await image, await icon)
    }

    private static func data(from provider: NSItemProvider?) async -> Data? {
        guard let provider else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    private static func image(from system: Data?, orAnyOf urls: [URL]) async -> Data? {
        if let system, let picture = Thumbnailer.make(from: system, maxPixels: imagePixels) { return picture.png }
        for url in urls.prefix(3) {
            if let data = await download(url), let picture = Thumbnailer.make(from: data, maxPixels: imagePixels) {
                return picture.png
            }
        }
        return nil
    }

    private static func icon(from page: LinkPage?, fallback: Data?) async -> Data? {
        var candidates = page?.icons ?? []
        if let manifest = page?.manifestURL, (candidates.first?.pixels ?? 0) < sharpIconPixels * 2, let data = await download(manifest) {
            candidates = LinkPage.largestFirst(LinkPage.icons(fromManifest: data, at: manifest) + candidates)
        }
        var best: Thumbnailer.Output?
        for candidate in candidates.prefix(6) {
            guard let data = await download(candidate.url), let found = Thumbnailer.icon(from: data, maxPixels: iconPixels) else { continue }
            if found.width > best?.width ?? 0 { best = found }
            if found.width >= sharpIconPixels { break }
        }
        if let fallback, let found = Thumbnailer.icon(from: fallback, maxPixels: iconPixels), found.width > best?.width ?? 0 {
            best = found
        }
        return best?.png
    }
}
