import CryptoKit
import Foundation
import Security

/// Owner commands from another AXTerm (Docs/RemoteAccessPlan.md, "Signing
/// in").
///
/// Each of the operator's devices has a P-256 key-agreement key; the
/// mailbox keeps the public keys of the devices paired with it. `OWNER KEY`
/// gets a one-time public key from the mailbox, and both ends derive the
/// same session key from it (ECDH, then HKDF over both callsigns) without
/// the key going on the air. The device proves it holds its key with one
/// full 128-bit check, and each owner command after that carries a 32-bit
/// check over a counter both ends keep and the command's text: `!a8F3kQ ST`.
/// Three wrong checks end the sign-in, so a forger gets three tries at
/// 1 in 4.3 billion; LTE and 5G guard their control messages the same way.
/// Nothing is hidden: the commands and checks are readable by anyone.
nonisolated enum OwnerKey {

    /// A device allowed to sign in, by the name the operator gave it.
    struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
        var name: String
        /// The device's key-agreement public key, base64.
        var publicKey: String
        var id: String { publicKey }
    }

    /// The owner commands. Signed in by key, each must carry its check.
    static let signedCommands: Set<String> = ["ST"]

    /// How long a challenge may wait for its answer.
    static let challengeLifetime: TimeInterval = 5 * 60

    /// Bytes of check: the sign-in's, and each command's.
    static let signInCheckBytes = 16
    static let commandCheckBytes = 4

    /// Wrong command checks before the sign-in ends.
    static let wrongChecksAllowed = 3

    /// Base64 of the compressed point: 44 characters.
    static func encode(_ key: P256.KeyAgreement.PublicKey) -> String {
        key.compressedRepresentation.base64EncodedString()
    }

    static func decode(_ text: String) -> P256.KeyAgreement.PublicKey? {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return (try? P256.KeyAgreement.PublicKey(compressedRepresentation: data))
            ?? (try? P256.KeyAgreement.PublicKey(x963Representation: data))
    }

    /// The session key from one end's private key and the other's public key.
    static func sessionKey(mine: P256.KeyAgreement.PrivateKey, theirs: String,
                           station: String, caller: String) -> SymmetricKey? {
        guard let other = decode(theirs),
              let shared = try? mine.sharedSecretFromKeyAgreement(with: other) else { return nil }
        return sessionKey(from: shared, station: station, caller: caller)
    }

    static func sessionKey(from shared: SharedSecret, station: String, caller: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("AXTerm owner session 3".utf8),
                                       sharedInfo: Data("\(station.uppercased())\n\(caller.uppercased())".utf8),
                                       outputByteCount: 32)
    }

    /// The first bytes of HMAC-SHA256 over the counter and the command, as
    /// base64 without padding: 6 characters for 4 bytes, 22 for 16.
    static func check(key: SymmetricKey, counter: UInt64, command: String, length: Int) -> String {
        var data = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        data.append(Data(command.utf8))
        let mac = Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        return mac.prefix(length).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Compares in constant time, so the time taken says nothing about how
    /// much of a guess was right.
    static func matches(_ given: String, _ expected: String) -> Bool {
        let a = Array(given.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    /// The mailbox's challenge line, with its one-time public key.
    static let challengePrefix = "Owner challenge: "

    /// What the mailbox says when the sign-in is over.
    static let signedOutLine = "Too many wrong checks. Sign in again: OWNER KEY."

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
    private static let account = "ownerDeviceAgreementKey"

    private enum Stored {
        case enclave(SecureEnclave.P256.KeyAgreement.PrivateKey)
        case software(P256.KeyAgreement.PrivateKey)

        var publicKey: P256.KeyAgreement.PublicKey {
            switch self {
            case .enclave(let key): key.publicKey
            case .software(let key): key.publicKey
            }
        }

        func sharedSecret(with other: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
            switch self {
            case .enclave(let key): try key.sharedSecretFromKeyAgreement(with: other)
            case .software(let key): try key.sharedSecretFromKeyAgreement(with: other)
            }
        }
    }

    private func stored() -> Stored? {
        if let text = keychain.string(account: Self.account) {
            if text.hasPrefix("se:"), let data = Data(base64Encoded: String(text.dropFirst(3))),
               let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data) {
                return .enclave(key)
            }
            if text.hasPrefix("sw:"), let data = Data(base64Encoded: String(text.dropFirst(3))),
               let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data) {
                return .software(key)
            }
        }
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey() {
            guard keychain.setString("se:" + key.dataRepresentation.base64EncodedString(),
                                     account: Self.account) else { return nil }
            return .enclave(key)
        }
        let key = P256.KeyAgreement.PrivateKey()
        guard keychain.setString("sw:" + key.rawRepresentation.base64EncodedString(),
                                 account: Self.account) else { return nil }
        return .software(key)
    }

    /// What the operator pastes into home's paired devices.
    func publicKeyText() -> String? {
        stored().map { OwnerKey.encode($0.publicKey) }
    }

    /// The session key for a mailbox's one-time key.
    func sessionKey(oneTime: String, station: String, caller: String) -> SymmetricKey? {
        guard let other = OwnerKey.decode(oneTime), let shared = try? stored()?.sharedSecret(with: other) else {
            return nil
        }
        return OwnerKey.sessionKey(from: shared, station: station, caller: caller)
    }
}

/// The terminal's side of owner commands by key. Sign In as Owner sends
/// `OWNER KEY`; the mailbox's challenge is answered with the sign-in check,
/// once, and only for the station asked. From then on an owner command the
/// operator types goes out with its check, the counter moving on each time.
nonisolated struct OwnerSignInResponder: Sendable {
    typealias Derive = (_ oneTimeKey: String, _ station: String, _ caller: String) -> SymmetricKey?

    private struct Session: @unchecked Sendable {
        let key: SymmetricKey
        var counter: UInt64
    }

    private var pending: Set<String> = []
    private var sessions: [String: Session] = [:]

    mutating func begin(peer: String) {
        pending.insert(peer.uppercased())
    }

    /// The session ended: nothing more is checked for it.
    mutating func end(peer: String) {
        let key = peer.uppercased()
        pending.remove(key)
        sessions[key] = nil
    }

    /// The line to send back, or nil when this line needs no answer.
    mutating func reply(toLine line: String, from peer: String, caller: String, derive: Derive) -> String? {
        let key = peer.uppercased()
        if line.hasPrefix(OwnerKey.signedOutLine) {
            sessions[key] = nil
            return nil
        }
        guard pending.contains(key), let oneTime = OwnerKey.challenge(inLine: line) else { return nil }
        pending.remove(key)
        guard let sessionKey = derive(oneTime, key, caller.uppercased()) else { return nil }
        sessions[key] = Session(key: sessionKey, counter: 1)
        return "OWNER MAC " + OwnerKey.check(key: sessionKey, counter: 0, command: "",
                                             length: OwnerKey.signInCheckBytes)
    }

    /// The line as it should go out: with its check when it is an owner
    /// command to a mailbox signed in to, nil to send it as typed.
    mutating func signed(line: String, to peer: String) -> String? {
        let key = peer.uppercased()
        let command = line.trimmingCharacters(in: .whitespaces)
        guard let verb = command.split(separator: " ").first.map({ $0.uppercased() }),
              OwnerKey.signedCommands.contains(verb),
              var session = sessions[key] else { return nil }
        let check = OwnerKey.check(key: session.key, counter: session.counter, command: command,
                                   length: OwnerKey.commandCheckBytes)
        session.counter += 1
        sessions[key] = session
        return "!" + check + " " + command
    }
}
