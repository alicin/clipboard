import CommonCrypto
import CryptoKit
import Foundation

public enum SyncError: Error, Equatable, CustomStringConvertible {
    case wrongPassphrase
    case needsReconnect
    case service(String)

    public var description: String {
        switch self {
        case .wrongPassphrase: "That passphrase doesn't match the one your other devices use."
        case .needsReconnect: "Google signed Clipboard out. Connect again to keep syncing."
        case .service(let message): message
        }
    }
}

/// Everything that leaves the Mac is sealed with a key made from the user's passphrase, so the cloud only ever holds
/// ciphertext. See docs/sync-format.md.
public struct SyncKeys: Sendable {
    public let master: Data
    private let sealing: SymmetricKey
    private let naming: SymmetricKey

    static let infoName = "sync-info.json"
    public static let defaultIterations = 600_000
    private static let checkText = Data("clipboard-sync".utf8)

    private struct Info: Codable {
        var format = 1
        let salt: Data
        let iterations: Int
        let check: Data
    }

    public init(master: Data) {
        self.master = master
        let input = SymmetricKey(data: master)
        sealing = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, info: Data("clipboard-sync seal".utf8), outputByteCount: 32)
        naming = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, info: Data("clipboard-sync name".utf8), outputByteCount: 32)
    }

    /// Joins what's already in the folder, or starts it if this is the first device.
    public static func join(_ backend: any SyncBackend, passphrase: String, iterations: Int = defaultIterations) async throws -> SyncKeys {
        let objects = try await backend.list()
        if objects.contains(where: { $0.name == infoName }) {
            guard let info = try? JSONDecoder().decode(Info.self, from: try await backend.read(infoName)),
                let master = derive(passphrase: passphrase, salt: info.salt, iterations: info.iterations)
            else { throw SyncError.wrongPassphrase }
            let keys = SyncKeys(master: master)
            guard keys.opensCheck(info.check) else { throw SyncError.wrongPassphrase }
            return keys
        }
        let salt = Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
        guard let master = derive(passphrase: passphrase, salt: salt, iterations: iterations) else {
            throw SyncError.service("Couldn't create an encryption key.")
        }
        let keys = SyncKeys(master: master)
        let info = Info(salt: salt, iterations: iterations, check: try keys.seal(checkText))
        _ = try await backend.write(infoName, data: try JSONEncoder().encode(info))
        return keys
    }

    func matchesInfo(_ data: Data) -> Bool {
        guard let info = try? JSONDecoder().decode(Info.self, from: data) else { return false }
        return opensCheck(info.check)
    }

    private func opensCheck(_ check: Data) -> Bool {
        (try? open(check)) == Self.checkText
    }

    private static func derive(passphrase: String, salt: Data, iterations: Int) -> Data? {
        var derived = Data(count: 32)
        let password = Array(passphrase.utf8).map { Int8(bitPattern: $0) }
        let status = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { input in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                    input.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                    output.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    func seal(_ data: Data) throws -> Data {
        guard let sealed = try AES.GCM.seal(data, using: sealing).combined else {
            throw SyncError.service("Couldn't encrypt a clip.")
        }
        return sealed
    }

    func open(_ data: Data) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: sealing)
    }

    /// Keyed, so a name can't be matched against a guess at what someone copied.
    func objectName(forHash hash: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(hash.utf8), using: naming).map { String(format: "%02x", $0) }.joined()
    }
}
