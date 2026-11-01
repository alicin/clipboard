import AppKit
import LinkPresentation
import ClipboardCore
import Vision

@MainActor
final class ClipEnricher {
    private let store: ClipStore
    private let preferences: Preferences

    init(store: ClipStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    func process(_ result: CaptureResult) {
        // A link with a token in it would hand the token to the site.
        guard result.isNew, !result.clip.isSecret else { return }
        switch result.clip.kind {
        case .image: recognizeText(in: result.clip)
        case .link where preferences.linkPreviews: fetchLinkPreview(for: result.clip)
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

    /// Hosts that only resolve inside the user's network shouldn't be contacted just because a URL was copied.
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

    private func fetchLinkPreview(for clip: Clip) {
        guard let preview = clip.preview, let url = ClipClassifier.linkURL(from: preview), Self.isPublicWebURL(url) else {
            return
        }
        let provider = LPMetadataProvider()
        provider.timeout = 8
        let store = store
        provider.startFetchingMetadata(for: url) { metadata, _ in
            guard let metadata else { return }
            let title = metadata.title
            let finish: @Sendable (Data?) -> Void = { thumbnail in
                try? store.setLinkMetadata(title: title, thumbnail: thumbnail, clipID: clip.id)
                DispatchQueue.main.async { NotificationCenter.default.post(name: .clipsChanged, object: nil) }
            }
            guard let imageProvider = metadata.imageProvider else {
                finish(nil)
                return
            }
            imageProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                finish(data.flatMap { Thumbnailer.make(from: $0, maxPixels: 720)?.png })
            }
        }
    }
}
