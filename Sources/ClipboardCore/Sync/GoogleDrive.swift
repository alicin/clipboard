import CryptoKit
import Foundation
import Network

/// The user's own Google Cloud client. Google treats a desktop app's secret as not really secret, since any installed copy
/// could read it, so holding it in the keychain is plenty.
public struct GoogleClient: Sendable, Equatable {
    public let id: String
    public let secret: String

    public init(id: String, secret: String) {
        self.id = id
        self.secret = secret
    }
}

private struct GoogleTokens: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private enum GoogleTokenEndpoint {
    static let url = URL(string: "https://oauth2.googleapis.com/token")!

    static func request(_ fields: [String: String], session: URLSession) async throws -> GoogleTokens {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(
            fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
                .joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let problem = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch problem?["error"] as? String {
            case "invalid_grant": throw SyncError.needsReconnect
            case "invalid_client", "unauthorized_client":
                throw SyncError.service("Google didn't accept that client ID and secret. Check they're from a Desktop app client.")
            default: throw SyncError.service("Google wouldn't sign Clipboard in: \(problem?["error"] as? String ?? "unknown error").")
            }
        }
        return try JSONDecoder().decode(GoogleTokens.self, from: data)
    }
}

public enum GoogleSignIn {
    /// Only the app's own hidden folder, which Drive keeps apart from the user's files.
    static let scope = "https://www.googleapis.com/auth/drive.appdata"

    /// A Desktop app client takes any local port, but a Web application client only takes a redirect it lists exactly.
    public static let redirectPort: UInt16 = 53847
    public static var redirectURI: String { "http://127.0.0.1:\(redirectPort)" }

    static func authorizationURL(client: GoogleClient, redirect: String, state: String, challenge: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            // Without this, signing in a second time returns no refresh token.
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    private static func randomToken() -> String {
        base64URL(Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // If something else holds the usual port, a Desktop app client can still sign in on another.
    private static func openReceiver() async throws -> (LoopbackReceiver, UInt16) {
        let usual = try LoopbackReceiver(port: NWEndpoint.Port(rawValue: redirectPort) ?? .any)
        if let port = try? await usual.start() { return (usual, port) }
        usual.stop()
        let fallback = try LoopbackReceiver(port: .any)
        return (fallback, try await fallback.start())
    }

    /// Walks the user through Google's page in their browser, and returns the refresh token to keep.
    public static func run(client: GoogleClient, session: URLSession = .shared, open: @Sendable (URL) -> Void) async throws -> String {
        let (receiver, port) = try await openReceiver()
        defer { receiver.stop() }
        let redirect = "http://127.0.0.1:\(port)"
        let state = randomToken()
        let verifier = randomToken()
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        open(authorizationURL(client: client, redirect: redirect, state: state, challenge: challenge))

        let answer = try await receiver.waitForRedirect()
        guard answer["state"] == state else { throw SyncError.service("Google's answer didn't match this sign-in. Try again.") }
        guard let code = answer["code"] else {
            throw SyncError.service(answer["error"] == "access_denied" ? "Google Drive access wasn't allowed." : "Google didn't finish signing in.")
        }
        let tokens = try await GoogleTokenEndpoint.request(
            [
                "grant_type": "authorization_code", "code": code, "client_id": client.id, "client_secret": client.secret,
                "redirect_uri": redirect, "code_verifier": verifier,
            ], session: session)
        guard let refresh = tokens.refreshToken else { throw SyncError.service("Google didn't return a long-lived sign-in. Try again.") }
        return refresh
    }
}

/// Answers the one request Google's page sends back to the app. Bound to loopback, so nothing else on the network can reach it.
private final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.bunniesinc.clipboard.google-sign-in")
    private var answer: CheckedContinuation<[String: String], Error>?

    private static let page = """
        <!doctype html><meta charset="utf-8"><title>Clipboard</title>
        <body style="font: 15px -apple-system, sans-serif; text-align: center; padding-top: 18vh">
        <h2>Back to Clipboard</h2><p>You can close this tab.</p></body>
        """

    init(port: NWEndpoint.Port) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            var pending: CheckedContinuation<UInt16, Error>? = continuation
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    pending?.resume(returning: listener.port?.rawValue ?? 0)
                    pending = nil
                case .failed(let error), .waiting(let error):
                    pending?.resume(throwing: error)
                    pending = nil
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func waitForRedirect() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.answer = continuation }
            }
        } onCancel: {
            queue.async {
                self.answer?.resume(throwing: CancellationError())
                self.answer = nil
            }
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let items = parts.count > 1 ? URLComponents(string: String(parts[1]))?.queryItems : nil
            let isAnswer = items?.contains { $0.name == "code" || $0.name == "error" } == true
            // Browsers also ask for a favicon.
            let reply = isAnswer
                ? "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(Self.page)"
                : "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard isAnswer, let items else { return }
            self.answer?.resume(returning: Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first }))
            self.answer = nil
        }
    }
}

/// Clips live in Drive's app data folder, which the user can't browse and other apps can't read. Drive keeps that folder
/// per app, so every device has to use the same client.
public actor GoogleDriveBackend: SyncBackend {
    private let client: GoogleClient
    private let refreshToken: String
    private let session: URLSession
    private var accessToken: String?
    private var tokenExpiry = Date.distantPast
    private var ids: [String: String] = [:]

    private static let files = "https://www.googleapis.com/drive/v3/files"
    private static let uploads = "https://www.googleapis.com/upload/drive/v3/files"

    private struct FileList: Decodable {
        struct File: Decodable {
            let id: String
            let name: String
            let md5Checksum: String?
            let modifiedTime: String?
        }
        let files: [File]
        let nextPageToken: String?
    }

    private struct Uploaded: Decodable {
        let id: String
        let md5Checksum: String?
    }

    public init(client: GoogleClient, refreshToken: String, session: URLSession = .shared) {
        self.client = client
        self.refreshToken = refreshToken
        self.session = session
    }

    public func list() async throws -> [SyncObject] {
        var found: [FileList.File] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: Self.files)!
            components.queryItems = [
                URLQueryItem(name: "spaces", value: "appDataFolder"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,md5Checksum,modifiedTime)"),
            ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let (data, _) = try await send(URLRequest(url: components.url!))
            let page = try JSONDecoder().decode(FileList.self, from: data)
            found += page.files
            pageToken = page.nextPageToken
        } while pageToken != nil

        // Drive allows two files with one name, which happens when two devices upload the same clip at once.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var newest: [String: (file: FileList.File, modified: Date)] = [:]
        for file in found {
            let modified = file.modifiedTime.flatMap(formatter.date(from:)) ?? .distantPast
            if let current = newest[file.name], current.modified >= modified {
                try? await delete(id: file.id)
            } else {
                if let current = newest[file.name] { try? await delete(id: current.file.id) }
                newest[file.name] = (file, modified)
            }
        }
        ids = newest.mapValues(\.file.id)
        return newest.values.map { SyncObject(name: $0.file.name, version: $0.file.md5Checksum ?? $0.file.modifiedTime ?? "", modified: $0.modified) }
    }

    public func read(_ name: String) async throws -> Data {
        guard let id = ids[name] else { throw SyncError.service("\(name) is no longer in Google Drive.") }
        let (data, _) = try await send(URLRequest(url: URL(string: "\(Self.files)/\(id)?alt=media")!))
        return data
    }

    public func write(_ name: String, data: Data) async throws -> String {
        // A resumable session handles any size with one code path, where a plain upload tops out at 5 MB.
        var start: URLRequest
        if let id = ids[name] {
            start = URLRequest(url: URL(string: "\(Self.uploads)/\(id)?uploadType=resumable&fields=id,md5Checksum")!)
            start.httpMethod = "PATCH"
            start.httpBody = Data("{}".utf8)
        } else {
            start = URLRequest(url: URL(string: "\(Self.uploads)?uploadType=resumable&fields=id,md5Checksum")!)
            start.httpMethod = "POST"
            start.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "parents": ["appDataFolder"]])
        }
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Upload-Content-Length")
        let (_, response) = try await send(start)
        guard let location = response.value(forHTTPHeaderField: "Location"), let target = URL(string: location) else {
            throw SyncError.service("Google Drive didn't start the upload.")
        }

        var upload = URLRequest(url: target)
        upload.httpMethod = "PUT"
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upload.httpBody = data
        let (answer, _) = try await send(upload)
        let uploaded = try JSONDecoder().decode(Uploaded.self, from: answer)
        ids[name] = uploaded.id
        return uploaded.md5Checksum ?? Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func delete(_ name: String) async throws {
        guard let id = ids[name] else { return }
        try await delete(id: id)
        ids[name] = nil
    }

    private func delete(id: String) async throws {
        var request = URLRequest(url: URL(string: "\(Self.files)/\(id)")!)
        request.httpMethod = "DELETE"
        _ = try await send(request, allowing: [404])
    }

    /// The Google account behind the connection, to show in Settings.
    public func accountEmail() async throws -> String? {
        struct About: Decodable {
            struct User: Decodable { let emailAddress: String? }
            let user: User?
        }
        let url = URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)")!
        let (data, _) = try await send(URLRequest(url: url))
        return try JSONDecoder().decode(About.self, from: data).user?.emailAddress
    }

    private func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, tokenExpiry > Date() { return accessToken }
        let tokens = try await GoogleTokenEndpoint.request(
            ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": client.id, "client_secret": client.secret],
            session: session)
        guard let fresh = tokens.accessToken else { throw SyncError.needsReconnect }
        accessToken = fresh
        tokenExpiry = Date().addingTimeInterval((tokens.expiresIn ?? 3600) - 60)
        return fresh
    }

    private func send(_ request: URLRequest, allowing allowed: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        var authorized = request
        authorized.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        var (data, response) = try await session.data(for: authorized)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            authorized.setValue("Bearer \(try await token(forceRefresh: true))", forHTTPHeaderField: "Authorization")
            (data, response) = try await session.data(for: authorized)
        }
        guard let http = response as? HTTPURLResponse else { throw SyncError.service("Google Drive sent an unreadable answer.") }
        guard (200..<300).contains(http.statusCode) || allowed.contains(http.statusCode) else {
            throw SyncError.service(Self.problem(in: data, status: http.statusCode))
        }
        return (data, http)
    }

    private static func problem(in data: Data, status: Int) -> String {
        struct Failure: Decodable {
            struct Body: Decodable {
                struct Detail: Decodable { let reason: String? }
                let message: String?
                let errors: [Detail]?
            }
            let error: Body?
        }
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        switch failure?.error?.errors?.first?.reason {
        case "accessNotConfigured": return "The Google Drive API isn't turned on for your Google app yet. Step 2 above does that."
        case "storageQuotaExceeded": return "Your Google Drive is full, so clips can't sync until there's room."
        case "rateLimitExceeded", "userRateLimitExceeded": return "Google Drive asked Clipboard to slow down. It'll try again soon."
        default: return failure?.error?.message ?? "Google Drive answered with error \(status)."
        }
    }
}
