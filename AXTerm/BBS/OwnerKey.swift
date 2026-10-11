import CryptoKit
import Foundation
import Security

/// Owner commands from another AXTerm, signed with a key pair
/// (Docs/RemoteAccessPlan.md, "Signing in").
///
/// Each of the operator's devices has a P-256 signing key; the mailbox keeps
/// the public keys of the devices paired with it. The mailbox sends a fresh
/// challenge, used once, and the device signs it together with the
/// mailbox's callsign, its own callsign and the command (empty to sign in).
/// A recorded signature is no good for another challenge, station, caller
/// or command. The challenge and signature go out as plain text beside the
/// commands, which stay readable: proof, not a cipher.
nonisolated enum OwnerKey {

    /// A device allowed to sign in, by the name the operator gave it.
    struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
        var name: String
        /// The public key, base64 of its X9.63 form.
        var publicKey: String
        var id: String { publicKey }
    }

    /// The owner commands. Signed in by key, each must carry a signature.
    static let signedCommands: Set<String> = ["ST"]

    /// How long a challenge may wait for its signature.
    static let challengeLifetime: TimeInterval = 5 * 60

    /// What is signed.
    static func message(challenge: String, station: String, caller: String, command: String) -> Data {
        Data("AXTerm owner command 2\n\(station.uppercased())\n\(caller.uppercased())\n\(challenge)\n\(command)".utf8)
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

    /// Sixteen random bytes as hex: 128 bits, as strong as P-256 itself.
    static func newChallenge() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// The signature, base64 of its 64-byte raw form.
    static func sign(challenge: String, station: String, caller: String, command: String,
                     with key: P256.Signing.PrivateKey) throws -> String {
        try key.signature(for: message(challenge: challenge, station: station, caller: caller, command: command))
            .rawRepresentation.base64EncodedString()
    }

    static func verify(signature: String, challenge: String, station: String, caller: String, command: String,
                       paired: [PairedDevice]) -> Bool {
        guard let raw = Data(base64Encoded: signature),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        let signed = message(challenge: challenge, station: station, caller: caller, command: command)
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

    /// A signature over a command (empty to sign in) for a mailbox's challenge.
    func sign(challenge: String, station: String, caller: String, command: String) -> String? {
        try? stored()?.signature(for: OwnerKey.message(challenge: challenge, station: station, caller: caller,
                                                       command: command))
            .rawRepresentation.base64EncodedString()
    }
}

/// The terminal's side of owner commands by key. Sign In as Owner sends
/// `OWNER KEY`; the mailbox's challenge is answered with a signature over no
/// command, once, and only for the station asked. From then on each reply
/// brings the next challenge, and an owner command the operator types goes
/// out as `OWNER SIG <signature> <command>` with it.
nonisolated struct OwnerSignInResponder: Sendable {
    typealias Sign = (_ challenge: String, _ station: String, _ caller: String, _ command: String) -> String?

    private var pending: Set<String> = []
    private var signedIn: Set<String> = []
    /// The last challenge from each signed-in mailbox, until a command uses it.
    private var current: [String: String] = [:]

    mutating func begin(peer: String) {
        pending.insert(peer.uppercased())
    }

    /// The session ended: nothing more is signed for it.
    mutating func end(peer: String) {
        let key = peer.uppercased()
        pending.remove(key)
        signedIn.remove(key)
        current[key] = nil
    }

    /// The line to send back, or nil when this line needs no answer.
    mutating func reply(toLine line: String, from peer: String, caller: String, sign: Sign) -> String? {
        let key = peer.uppercased()
        guard let challenge = OwnerKey.challenge(inLine: line) else { return nil }
        guard pending.contains(key) else {
            if signedIn.contains(key) { current[key] = challenge }
            return nil
        }
        pending.remove(key)
        guard let signature = sign(challenge, key, caller.uppercased(), "") else { return nil }
        signedIn.insert(key)
        return "OWNER SIG \(signature)"
    }

    /// The line as it should go out: signed when it is an owner command to
    /// a mailbox signed in to, nil to send it as typed.
    mutating func signed(line: String, to peer: String, caller: String, sign: Sign) -> String? {
        let key = peer.uppercased()
        let command = line.trimmingCharacters(in: .whitespaces)
        guard let verb = command.split(separator: " ").first.map({ $0.uppercased() }),
              OwnerKey.signedCommands.contains(verb),
              let challenge = current[key] else { return nil }
        current[key] = nil
        guard let signature = sign(challenge, key, caller.uppercased(), command) else { return nil }
        return "OWNER SIG \(signature) \(command)"
    }
}
