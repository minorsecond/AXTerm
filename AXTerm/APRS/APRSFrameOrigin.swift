import Foundation

/// How a frame reached the air: off a transmitter, or off the internet and
/// put onto RF by a gateway.
///
/// The two are indistinguishable on the map unless something says so. A
/// station whose traffic is piped in from APRS-IS looks exactly like a
/// neighbour — same symbol, same list, same "heard" count — while telling you
/// nothing about what your radio can actually reach. In a grid-down week the
/// difference is the whole point: the internet-fed half of the map is the half
/// that disappears.
///
/// This reads only what the frame states outright. It does not guess from
/// distance — `StationPlausibility` does that, and the two are deliberately
/// separate: one is a fact the sender published, the other is an inference
/// from geometry. A frame can be either, both, or neither.
nonisolated enum APRSFrameOrigin: Hashable, Sendable {

    /// Nothing in the frame says otherwise. Not proof of RF — just no claim
    /// to the contrary.
    case radio

    /// A third-party frame (`}`): `originator` sent it, it travelled over the
    /// internet, and `gateway` transmitted it here. Both names come from the
    /// frame's own header.
    case gatedOntoRF(originator: String, gateway: String)

    /// The frame's own path is marked as having come from the internet.
    case internetPath

    var isFromInternet: Bool { self != .radio }

    /// The station that put it on RF, when the frame names one.
    var gateway: String? {
        if case .gatedOntoRF(_, let gateway) = self { return gateway }
        return nil
    }

    /// Path elements that mean "this travelled over the internet". `TCPIP`
    /// and `TCPXX` are APRS-IS's own markers; `qA*` is the q-construct an
    /// igate stamps on, and it can only be applied by a server.
    static func marksInternet(_ element: String) -> Bool {
        let e = element.uppercased()
        return e.hasPrefix("TCPIP") || e.hasPrefix("TCPXX") || e.hasPrefix("QA")
    }

    /// Classifies a received frame.
    ///
    /// - Parameters:
    ///   - info: the information field, verbatim.
    ///   - via: the AX.25 digipeater path as heard, `*` included or not.
    static func classify(info: Data, via: [String]) -> APRSFrameOrigin {
        if let text = String(data: info, encoding: .utf8) ?? String(data: info, encoding: .ascii),
           text.first == "}",
           let inner = thirdPartyHeader(text) {
            // Only claim the internet when the inner path says so. A third
            // party frame can also be an RF-to-RF relay, and calling that
            // "from the internet" would be a lie in the safer direction's
            // favour — the operator would discount a station they can reach.
            if inner.path.contains(where: marksInternet) {
                return .gatedOntoRF(originator: inner.originator,
                                    gateway: inner.gateway ?? "unknown")
            }
            return .radio
        }
        if via.contains(where: { marksInternet($0.replacingOccurrences(of: "*", with: "")) }) {
            return .internetPath
        }
        return .radio
    }

    /// Splits `}SRC>DEST,path:payload` into the parts that say where it came
    /// from. The gateway is the last path element flagged used (`*`), which
    /// is the station whose transmitter we actually heard.
    private static func thirdPartyHeader(
        _ text: String
    ) -> (originator: String, path: [String], gateway: String?)? {
        let body = text.dropFirst()                      // past `}`
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let header = body[body.startIndex..<colon]
        guard let arrow = header.firstIndex(of: ">") else { return nil }
        let originator = String(header[header.startIndex..<arrow])
        guard !originator.isEmpty else { return nil }
        let afterArrow = header[header.index(after: arrow)...]
        // `DEST,via,via…` — the destination is not part of the path.
        let elements = afterArrow.split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        let path = Array(elements.dropFirst())
        let gateway = path.last(where: { $0.hasSuffix("*") })?
            .replacingOccurrences(of: "*", with: "")
        return (originator, path, gateway)
    }
}
