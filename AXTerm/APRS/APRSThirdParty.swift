//
//  APRSThirdParty.swift
//  AXTerm
//
//  The header of a third-party frame (APRS 1.01 chapter 17), the form an
//  igate uses to put a packet from APRS-IS, or a relay one from another
//  channel, onto RF:
//
//      }KJ5PEC-13>APRS,TCPIP,W0NED*:@161843z3936.25N/10442.50W_...
//
//  The station we heard is the gateway (W0NED). Everything after the colon is
//  the original packet, sent by the source (KJ5PEC-13), and its position,
//  weather or object belongs to the source, never to the gateway. Smoke run
//  2026-10-03-1, issue 27: these were shown raw in the terminal, because
//  every parser but the message one gave up on the leading `}`.
//
//  One level only: a third-party frame inside a third-party frame is left as
//  the inner payload says, rather than unwrapped again.
//

import Foundation

nonisolated struct APRSThirdParty: Equatable, Sendable {
    /// The station that sent the original packet.
    let source: String
    /// The original packet's destination, which Mic-E reads its latitude
    /// from.
    let destination: String
    /// The original packet's path, `*` marks included.
    let path: [String]
    /// The original packet, byte for byte.
    let payload: Data

    /// The station that put it on RF, when the path names one: the last
    /// element flagged used.
    var gateway: String? {
        path.last(where: { $0.hasSuffix("*") })?.replacingOccurrences(of: "*", with: "")
    }

    /// The original packet traveled over the internet (TCPIP, TCPXX or a qA
    /// construct in its path), not only over another radio channel.
    var viaInternet: Bool { path.contains(where: APRSFrameOrigin.marksInternet) }

    /// The header of `info`, when it is a third-party frame.
    static func unwrap(info: Data) -> APRSThirdParty? {
        guard info.first == UInt8(ascii: "}"),
              let colon = info.dropFirst().firstIndex(of: UInt8(ascii: ":")) else { return nil }
        let headerBytes = info[info.index(after: info.startIndex)..<colon]
        guard let header = String(data: headerBytes, encoding: .ascii),
              let arrow = header.firstIndex(of: ">") else { return nil }
        let source = String(header[header.startIndex..<arrow]).trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return nil }
        let elements = header[header.index(after: arrow)...]
            .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let destination = elements.first, !destination.isEmpty else { return nil }
        return APRSThirdParty(source: source, destination: destination,
                              path: Array(elements.dropFirst()),
                              payload: Data(info[info.index(after: colon)...]))
    }
}

/// What a station that sends third-party frames is doing: putting other
/// stations' packets onto RF. Its own transmitter is the one heard, so this
/// says nothing against its own position or reach.
nonisolated struct APRSGatewayActivity: Hashable, Sendable {
    /// The source of the latest packet it relayed.
    let lastSource: String
    /// Whether that packet came from the internet rather than another
    /// channel.
    let viaInternet: Bool
}
