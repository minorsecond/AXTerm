//
//  BeaconPlan.swift
//  AXTerm
//
//  What this station says about itself, unprompted, on a timer.
//
//  Every node on the channel does this — `KE0NCQ/R DRL/D DRLBBS/B
//  DRLNOD/N`, or the Denver Radio League's net announcement — and until
//  now AXTerm was the only station listening to them without ever
//  answering in kind. A beacon is how a passing station learns this one
//  exists at all.
//
//  Deliberately not the NODES broadcast, which is on its own timer and
//  carries a binary routing structure rather than prose. The two look
//  alike from a distance and are not alike at all: one is a sentence for
//  a human, the other is a table for a router.
//
//  Validation lives here, apart from the timer and the settings screen,
//  because everything it rejects is something that would otherwise go out
//  over the air and stay there.
//

import Foundation

nonisolated enum BeaconPlan {

    /// The conventional unconnected destination for an unsolicited
    /// announcement. Not configurable: `BEACON` is what the rest of the
    /// channel uses, and it is what AXTerm's own classifier looks for.
    static let destinationCall = "BEACON"

    /// AX.25 allows eight digipeaters in the address field. Beyond about
    /// two the frame is mostly addresses and every hop is another
    /// chance for a collision, but the ceiling is the spec's.
    static let maxDigis = 8

    /// A beacon long enough to need fragmenting is not a beacon. This is
    /// one frame's worth at a generous PACLEN, and well under the 256
    /// bytes an AX.25 info field allows.
    static let maxTextBytes = 200

    enum Problem: Error, Equatable {
        case emptyText
        case textTooLong(bytes: Int)
        case tooManyDigis(count: Int)
        case malformedDigi(String)

        var operatorText: String {
            switch self {
            case .emptyText:
                return "A beacon needs something to say."
            case let .textTooLong(bytes):
                return "Beacon text is \(bytes) bytes; the limit is \(maxTextBytes). "
                    + "A beacon that fills the channel stops being neighbourly."
            case let .tooManyDigis(count):
                return "\(count) digipeaters; AX.25 allows \(maxDigis). "
                    + "Past two the frame is mostly addresses anyway."
            case let .malformedDigi(text):
                return "\"\(text)\" is not a callsign, so it cannot be a digipeater."
            }
        }
    }

    struct Beacon: Equatable {
        let text: String
        let digis: [String]
    }

    /// Turn what the operator typed into something transmittable, or say
    /// why it is not.
    ///
    /// The path is free text because that is how operators write paths —
    /// `WIDE1-1,WIDE2-1`, `DRL WIDE2-1`, with whatever spacing. Splitting
    /// on both separators costs nothing and spares a format rule nobody
    /// would read.
    static func plan(text: String, path: String) -> Result<Beacon, Problem> {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .failure(.emptyText) }
        let bytes = body.utf8.count
        guard bytes <= maxTextBytes else { return .failure(.textTooLong(bytes: bytes)) }

        let tokens = path
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).uppercased() }
        guard tokens.count <= maxDigis else {
            return .failure(.tooManyDigis(count: tokens.count))
        }
        for token in tokens where !isCallsignShaped(token) {
            return .failure(.malformedDigi(token))
        }
        return .success(Beacon(text: body, digis: tokens))
    }

    /// Loose on purpose. `WIDE1-1` and `DRL` are both legitimate here and
    /// neither is a licence, so the licence-shaped test used elsewhere
    /// would reject the two most common entries an operator types.
    private static func isCallsignShaped(_ token: String) -> Bool {
        let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let call = parts.first, (1...6).contains(call.count),
              call.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return false }
        guard parts.count == 2 else { return true }
        guard let ssid = Int(parts[1]), (0...15).contains(ssid) else { return false }
        return true
    }
}
