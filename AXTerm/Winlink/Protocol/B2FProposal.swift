import Foundation

/// FBB B2F proposal lines and their answers.
///
/// A sender offers up to five messages per block with `FC` lines, closes
/// the block with `F> XX` (XX = checksum), and the receiver answers with
/// one `FS` line carrying one answer code per proposal, in order.
nonisolated enum B2FProposal {

    static let maxProposalsPerBlock = 5

    /// One `FC` proposal: `FC EM <MID> <uncompressed> <compressed> 0`.
    struct Proposal: Equatable, Sendable {
        enum Kind: String, Sendable {
            case encapsulatedMessage = "EM"  // regular B2 message
            case controlMessage = "CM"       // Winlink control message
        }

        var kind: Kind
        var mid: String
        var uncompressedSize: Int
        var compressedSize: Int

        var rendered: String {
            "FC \(kind.rawValue) \(mid) \(uncompressedSize) \(compressedSize) 0\r"
        }

        /// Parses an `FC` line (without trailing CR/LF).
        static func parse(_ line: String) -> Proposal? {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 5, parts[0].uppercased() == "FC" else { return nil }
            guard let kind = Kind(rawValue: parts[1].uppercased()),
                  let uSize = Int(parts[3]),
                  let cSize = Int(parts[4]),
                  uSize >= 0, cSize >= 0
            else { return nil }
            return Proposal(kind: kind, mid: parts[2], uncompressedSize: uSize, compressedSize: cSize)
        }
    }

    /// The receiver's verdict on one proposal.
    enum Answer: Equatable, Sendable {
        case accept              // Y or +
        case reject              // N, R, -, E or H (never resend)
        case defer_              // L or = (try again next session)
        case acceptFromOffset(Int)  // A/!/+ with a byte offset (partial resume)

        var rendered: String {
            switch self {
            case .accept: return "Y"
            case .reject: return "N"
            case .defer_: return "="
            case .acceptFromOffset(let offset): return "!\(offset)"
            }
        }
    }

    /// Renders a full proposal block: FC lines followed by `F> XX`.
    /// The checksum sums every character of the FC lines including each
    /// trailing CR.
    static func renderBlock(_ proposals: [Proposal]) -> String {
        var block = ""
        for proposal in proposals { block += proposal.rendered }
        let checksum = B2FChecksum.negatedByteSum(of: Array(block.utf8))
        block += String(format: "F> %02X\r", checksum)
        return block
    }

    /// Validates the `F> XX` checksum for previously collected FC lines.
    static func validateBlockChecksum(fcLines: [String], checksumHex: String) -> Bool {
        guard let stated = UInt8(checksumHex, radix: 16) else { return false }
        var bytes = [UInt8]()
        for line in fcLines {
            bytes.append(contentsOf: Array(line.utf8))
            bytes.append(0x0d)
        }
        return B2FChecksum.negatedByteSum(of: bytes) == stated
    }

    /// Parses an `FS` answer line, e.g. `FS YN=!247Y`.
    ///
    /// Answer letters per the FBB/B2F spec: `Y`/`+` accept, `N`/`R`/`-`/`E`
    /// reject, `L`/`=`/`H` defer, and `A`/`!` accept-from-offset with a
    /// decimal offset directly after the marker (`+` may also carry one).
    static func parseAnswers(_ line: String) -> [Answer]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix("FS") else { return nil }

        var answers = [Answer]()
        var characters = Array(trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces).uppercased())
        var index = 0
        while index < characters.count {
            let char = characters[index]
            index += 1
            switch char {
            case "Y":
                answers.append(.accept)
            case "N", "R", "-", "E":
                answers.append(.reject)
            case "L", "=", "H":
                answers.append(.defer_)
            case "+", "A", "!":
                var digits = ""
                while index < characters.count, characters[index].isNumber {
                    digits.append(characters[index])
                    index += 1
                }
                if digits.isEmpty {
                    answers.append(char == "!" || char == "A" ? .acceptFromOffset(0) : .accept)
                } else {
                    let offset = min(Int(digits) ?? 0, 999_999)
                    answers.append(offset == 0 ? .accept : .acceptFromOffset(offset))
                }
            default:
                return nil  // unknown answer code — treat the line as unparseable
            }
        }
        return answers
    }
}
