import CryptoKit
import Foundation
import Security

/// Six-digit time-based one-time codes (TOTP, RFC 6238: HMAC-SHA-1, 30 s
/// steps) for the operator's owner commands from a plain terminal
/// (Docs/RemoteAccessPlan.md, "Signing in").
///
/// A code proves who typed the command; it hides nothing. The command goes
/// out in plain text with the six digits beside it, which anyone listening
/// can read, so each code is accepted once and only within a step of the
/// mailbox's clock.
nonisolated enum OwnerCode {

    static let digits = 6
    static let period: TimeInterval = 30

    /// The code for `date`.
    static func code(secret: Data, at date: Date) -> String {
        code(secret: secret, step: step(at: date))
    }

    static func step(at date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970) / period)
    }

    static func code(secret: Data, step: UInt64) -> String {
        var counter = step.bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
        // RFC 4226 dynamic truncation.
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let value = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        let code = value % 1_000_000
        return String(format: "%06u", code)
    }

    /// Twenty random bytes, the size RFC 4226 recommends.
    static func newSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    // MARK: - Setting up an authenticator app

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// RFC 4648 base32 without padding, as authenticator apps take it.
    static func base32(_ data: Data) -> String {
        var out = ""
        var buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    static func secret(fromBase32 text: String) -> Data? {
        var bytes: [UInt8] = []
        var buffer = 0, bits = 0
        for character in text.uppercased() where character != "=" && character != " " {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return bytes.isEmpty ? nil : Data(bytes)
    }

    /// The `otpauth://` link an authenticator app scans from a QR code.
    static func setupLink(secret: Data, station: String) -> String {
        "otpauth://totp/AXTerm:\(station.uppercased())?secret=\(base32(secret))"
            + "&issuer=AXTerm&digits=\(digits)&period=\(Int(period))"
    }

    // MARK: - Checking a typed code

    enum Verdict: Equatable, Sendable {
        case accepted
        case wrong
        /// Right, but that step (or a later one) was already used.
        case used
        /// Too many wrong codes lately; nothing is checked until it passes.
        case lockedOut
    }

    /// Checks typed codes for one secret, remembering what was used and
    /// how many were wrong.
    struct Checker: Sendable {
        let secret: Data
        /// One step either side of the mailbox's clock.
        static let drift: UInt64 = 1
        static let allowedWrong = 3
        /// The first lockout. Each one after it, with no right code
        /// between, is twice as long, up to `longestLockout`: a guesser at
        /// the fastest pace the lockout allows gets about 180 guesses a
        /// year, under 0.06% odds of a right one (each guess can match three
        /// codes). A fixed 15 minutes allowed some 93,000 guesses a year,
        /// 28% odds (security suite, SEC-1, 2026-10-12).
        static let lockout: TimeInterval = 15 * 60
        static let longestLockout: TimeInterval = 7 * 86_400

        private(set) var lastUsedStep: UInt64?
        private var wrongAt: [Date] = []
        private var lockedUntil: Date?
        /// Lockouts in a row, with no right code between.
        private var lockouts = 0

        init(secret: Data) { self.secret = secret }

        mutating func check(_ typed: String, at now: Date) -> Verdict {
            if let lockedUntil, now < lockedUntil { return .lockedOut }
            lockedUntil = nil
            let typed = typed.trimmingCharacters(in: .whitespaces)
            guard typed.count == OwnerCode.digits, typed.allSatisfy(\.isASCIIDigit) else { return wrong(at: now) }
            let current = OwnerCode.step(at: now)
            let lowest = current >= Self.drift ? current - Self.drift : 0
            for step in lowest...(current + Self.drift) where OwnerCode.code(secret: secret, step: step) == typed {
                if let lastUsedStep, step <= lastUsedStep { return .used }
                lastUsedStep = step
                wrongAt.removeAll()
                lockouts = 0
                return .accepted
            }
            return wrong(at: now)
        }

        private mutating func wrong(at now: Date) -> Verdict {
            wrongAt = wrongAt.filter { now.timeIntervalSince($0) < Self.lockout } + [now]
            if wrongAt.count >= Self.allowedWrong {
                let length = min(Self.lockout * pow(2, Double(min(lockouts, 30))), Self.longestLockout)
                lockedUntil = now.addingTimeInterval(length)
                lockouts += 1
                wrongAt.removeAll()
            }
            return .wrong
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Where the owner code's secret lives: the Keychain, never preferences,
/// since anyone holding it can sign in as the operator.
nonisolated struct OwnerCodeSecretStore: Sendable {
    private let keychain = KeychainStore(service: "com.axterm.mailbox")
    private static let account = "ownerCode"

    func read() -> Data? {
        keychain.string(account: Self.account).flatMap(OwnerCode.secret(fromBase32:))
    }

    /// Makes and saves a new secret; the old one stops working.
    @discardableResult
    func replace() -> Data? {
        let secret = OwnerCode.newSecret()
        return keychain.setString(OwnerCode.base32(secret), account: Self.account) ? secret : nil
    }
}
