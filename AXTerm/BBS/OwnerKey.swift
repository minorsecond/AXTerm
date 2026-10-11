import CryptoKit
import Foundation
import Security

/// Signing in as the owner from another AXTerm with a key pair
/// (Docs/RemoteAccessPlan.md, "Signing in").
///
/// Each of the operator's devices has a P-256 signing key; the mailbox keeps
/// the public keys of the devices paired with it. The mailbox sends a fresh
/// challenge, and the device signs "AXTerm owner sign-in", the mailbox's
/// callsign and the challenge. A recorded signature is no good for another
/// challenge or another station. The challenge and signature go out as
/// plain text beside the commands, which stay readable: proof, not a cipher.
nonisolated enum OwnerKey {

    /// A device allowed to sign in, by the name the operator gave it.
    struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
        var name: String
        /// The public key, base64 of its X9.63 form.
        var publicKey: String
        var id: String { publicKey }
    }

    /// What is signed.
    static func message(challenge: String, station: String) -> Data {
        Data("AXTerm owner sign-in\n\(station.uppercased())\n\(challenge)".utf8)
    }

    static func encode(_ key: P256.Signing.PublicKey) -> String {
        key.x963Representation.base64EncodedString()
    }

    static func decode(_ text: String) -> P256.Signing.PublicKey? {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return try? P256.Signing.PublicKey(x963Representation: data)
    }

    /// Sixteen random bytes as hex.
    static func newChallenge() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// The signature, base64 of its 64-byte raw form.
    static func sign(challenge: String, station: String, with key: P256.Signing.PrivateKey) throws -> String {
        try key.signature(for: message(challenge: challenge, station: station)).rawRepresentation
            .base64EncodedString()
    }

    static func verify(signature: String, challenge: String, station: String, paired: [PairedDevice]) -> Bool {
        guard let raw = Data(base64Encoded: signature),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        let signed = message(challenge: challenge, station: station)
        return paired.contains { device in
            decode(device.publicKey)?.isValidSignature(ecdsa, for: signed) ?? false
        }
    }

    /// The mailbox's challenge line.
    static let challengePrefix = "Owner challenge: "

    static func challenge(inLine line: String) -> String? {
        guard line.hasPrefix(challengePrefix) else { return nil }
        let value = line.dropFirst(challengePrefix.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

/// This device's own owner key, made on first use. In the Secure Enclave
/// where the device has one, so the private key never leaves the chip (the
/// Keychain keeps only the enclave's handle to it); a software key in the
/// Keychain elsewhere.
nonisolated struct OwnerDeviceKey: Sendable {
    private let keychain = KeychainStore(service: "com.axterm.mailbox")
    private static let account = "ownerDeviceKey"

    private enum Stored {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)

        var publicKey: P256.Signing.PublicKey {
            switch self {
            case .enclave(let key): key.publicKey
            case .software(let key): key.publicKey
            }
        }

        func signature(for data: Data) throws -> P256.Signing.ECDSASignature {
            switch self {
            case .enclave(let key): try key.signature(for: data)
            case .software(let key): try key.signature(for: data)
            }
        }
    }

    private func stored() -> Stored? {
        if let text = keychain.string(account: Self.account) {
            if text.hasPrefix("se:"), let data = Data(base64Encoded: String(text.dropFirst(3))),
               let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
                return .enclave(key)
            }
            if text.hasPrefix("sw:"), let data = Data(base64Encoded: String(text.dropFirst(3))),
               let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
                return .software(key)
            }
        }
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            guard keychain.setString("se:" + key.dataRepresentation.base64EncodedString(),
                                     account: Self.account) else { return nil }
            return .enclave(key)
        }
        let key = P256.Signing.PrivateKey()
        guard keychain.setString("sw:" + key.rawRepresentation.base64EncodedString(),
                                 account: Self.account) else { return nil }
        return .software(key)
    }

    /// What the operator pastes into home's paired devices.
    func publicKeyText() -> String? {
        stored().map { OwnerKey.encode($0.publicKey) }
    }

    /// The answer to a mailbox's challenge.
    func sign(challenge: String, station: String) -> String? {
        try? stored()?.signature(for: OwnerKey.message(challenge: challenge, station: station))
            .rawRepresentation.base64EncodedString()
    }
}

/// The terminal's side of a key sign-in: after Sign In as Owner sends
/// `OWNER KEY`, the mailbox's challenge line is answered with
/// `OWNER SIG <signature>`, once, and only from the station asked.
nonisolated struct OwnerSignInResponder: Sendable {
    private var pending: Set<String> = []

    mutating func begin(peer: String) {
        pending.insert(peer.uppercased())
    }

    /// The line to send back, or nil when this line needs no answer.
    mutating func reply(toLine line: String, from peer: String,
                        sign: (_ challenge: String, _ station: String) -> String?) -> String? {
        let key = peer.uppercased()
        guard pending.contains(key), let challenge = OwnerKey.challenge(inLine: line) else { return nil }
        pending.remove(key)
        guard let signature = sign(challenge, key) else { return nil }
        return "OWNER SIG \(signature)"
    }
}
