import Foundation
import CryptoKit

/// Winlink secure-login challenge/response (the `;PQ:` / `;PR:` exchange).
///
/// Algorithm ported from paclink-unix via la5nta/wl2k-go (MIT): the
/// response is derived from MD5(challenge + password + salt), where the
/// salt is a fixed 64-byte constant shared by all Winlink clients. MD5 is
/// mandated by the protocol here — this is an interop requirement, not a
/// security choice AXTerm gets to make.
nonisolated enum WinlinkSecureLogin {

    /// Computes the 8-digit decimal response for a `;PQ:` challenge.
    static func response(challenge: String, password: String) -> String {
        var payload = Data(challenge.utf8)
        payload.append(contentsOf: Data(password.utf8))
        payload.append(contentsOf: salt)

        let sum = Array(Insecure.MD5.hash(data: payload))

        var pr = Int32(sum[3] & 0x3f)
        for i in stride(from: 2, through: 0, by: -1) {
            pr = (pr << 8) | Int32(sum[i])
        }

        let digits = String(format: "%08d", pr)
        return String(digits.suffix(8))
    }

    /// Fixed salt from the paclink-unix reference implementation.
    private static let salt: [UInt8] = [
        77, 197, 101, 206, 190, 249,
        93, 200, 51, 243, 93, 237,
        71, 94, 239, 138, 68, 108,
        70, 185, 225, 137, 217, 16,
        51, 122, 193, 48, 194, 195,
        198, 175, 172, 169, 70, 84,
        61, 62, 104, 186, 114, 52,
        61, 168, 66, 129, 192, 208,
        187, 249, 232, 193, 41, 113,
        41, 45, 240, 16, 29, 228,
        208, 228, 61, 20,
    ]
}
