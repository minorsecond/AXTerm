import Foundation

/// How long a Winlink request will take on the air — and how much of
/// that answer is measured rather than assumed.
///
/// Two factors decide the number, and they have very different standing:
///
/// * **Throughput** is measurable. `WinlinkLinkQuality` already derives
///   bytes-per-second from AXTerm's own session logs, per gateway *per
///   frequency*, and the units line up exactly: `B2FSessionEngine`
///   accumulates `outbound.compressed.count`, so the logged bytes are
///   the same compressed wire bytes this estimate divides by. When a
///   usable measurement exists it replaces the default outright.
/// * **Compression** is not, yet. `FC EM <MID> <uncompressed>
///   <compressed> 0` carries both sizes on every proposal, but nothing
///   persists the uncompressed side, so there is no history to average.
///   3:1 stays an assumption — deliberately conservative, since the
///   2026-08-24 capture compressed catalog text 4.2:1. It is also
///   product-dependent in a way a per-link average would not capture:
///   weather fax and radar are not text.
///
/// Measurements are only used when they describe the link *from here*.
/// `WinlinkLinkQuality` treats RF reachability as a property of the pair
/// of endpoints, so a sample taken 200 km away is reported as context
/// and never as a prediction. Presenting someone else's path as your
/// throughput would be worse than admitting the default.
nonisolated struct WinlinkAirtimeEstimate: Equatable, Sendable {

    /// Why the rate is what it is. The UI must be able to tell a
    /// measurement from a stand-in, so this is never collapsed to a bare
    /// number.
    enum Basis: Equatable, Sendable {
        /// Measured on this link, from where the operator is now.
        case measured(gateway: String, bytesPerSecond: Double)
        /// No usable local measurement; the documented default stands in.
        case assumed(Assumption)
    }

    enum Assumption: Equatable, Sendable {
        /// No gateway configured, so there is no link to have measured.
        case noGateway
        /// Nothing logged for this link yet, or not enough of it —
        /// `effectiveBytesPerSecond` needs ten seconds of measured
        /// traffic before it means anything.
        case noSamples(gateway: String)
        /// Samples exist and are usable as *information*, but they do
        /// not describe the path from here. `kilometres` is nil when the
        /// samples predate position stamping.
        case samplesNotFromHere(gateway: String, bytesPerSecond: Double, kilometres: Double?)
    }

    /// B2F sends bodies LZHUF-compressed and catalog products are text.
    /// See the type comment for why this stays a constant.
    static let assumedCompressionRatio = 3.0

    /// Payload throughput for a healthy 1200-baud packet path.
    /// `WinlinkLinkQuality` treats ≥40 B/s as good and <15 B/s as
    /// struggling; the 2026-08-24 capture measured 29 B/s through a link
    /// losing 21% to retries. 30 B/s is a fair middle for a station with
    /// no history of its own.
    static let defaultCompressedBytesPerSecond = 30.0

    let basis: Basis

    /// Longest session this gateway has ever allowed, in seconds. Some
    /// gateways enforce a cap (W0ARP-10 disconnects at ~17 minutes),
    /// which bounds how much can move in one attempt no matter how good
    /// the path is. Nil when no cap has been observed.
    let sessionCapSeconds: Double?

    /// The estimate a station with no history of its own gets.
    static let assumed = WinlinkAirtimeEstimate(
        basis: .assumed(.noGateway), sessionCapSeconds: nil)

    // MARK: - Derived

    var isMeasured: Bool {
        if case .measured = basis { return true }
        return false
    }

    var compressedBytesPerSecond: Double {
        switch basis {
        case .measured(_, let rate): rate
        case .assumed: Self.defaultCompressedBytesPerSecond
        }
    }

    var gateway: String? {
        switch basis {
        case .measured(let gateway, _): gateway
        case .assumed(.noSamples(let gateway)): gateway
        case .assumed(.samplesNotFromHere(let gateway, _, _)): gateway
        case .assumed(.noGateway): nil
        }
    }

    func estimatedSeconds(bytes: Int) -> Double {
        guard bytes > 0 else { return 0 }
        return Double(bytes) / Self.assumedCompressionRatio / compressedBytesPerSecond
    }

    /// How many exchange sessions this needs, given the gateway's
    /// observed cap. 1 when it fits, or when no cap has been seen.
    func sessionsRequired(bytes: Int) -> Int {
        guard let cap = sessionCapSeconds, cap > 0 else { return 1 }
        let seconds = estimatedSeconds(bytes: bytes)
        guard seconds > cap else { return 1 }
        return max(1, Int((seconds / cap).rounded(.up)))
    }

    /// Airtime for bytes whose compressed size is already known.
    ///
    /// An FBB proposal states the compressed size exactly — `FC EM <MID>
    /// <uncompressed> <compressed> 0` — so the 3:1 assumption has no place
    /// here. Half the guesswork in `estimatedSeconds(bytes:)` disappears
    /// and only the throughput is estimated, which is the half that can at
    /// least be measured.
    func estimatedSecondsOnTheAir(compressedBytes: Int) -> Double {
        guard compressedBytes > 0 else { return 0 }
        return Double(compressedBytes) / compressedBytesPerSecond
    }

    /// Compact airtime label for a known compressed size.
    func airtimeTextOnTheAir(compressedBytes: Int) -> String {
        Self.durationText(estimatedSecondsOnTheAir(compressedBytes: compressedBytes))
    }

    /// Compact airtime label: "8s", "3 min", "1 hr 5 min".
    func airtimeText(bytes: Int) -> String {
        Self.durationText(estimatedSeconds(bytes: bytes))
    }

    /// One-line provenance for a footer or badge.
    var provenance: String {
        switch basis {
        case .measured(let gateway, let rate):
            "measured \(Self.rateText(rate)) to \(gateway)"
        case .assumed:
            "assumed \(Self.rateText(Self.defaultCompressedBytesPerSecond))"
        }
    }

    // MARK: - Tooltip

    /// Explains a size in the terms that decide whether to request it,
    /// and says plainly which half of the estimate is evidence.
    func tooltip(bytes: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let ratio = Int(Self.assumedCompressionRatio)
        var text = """
        \(size) of text, roughly \(airtimeText(bytes: bytes)) of airtime.

        Estimated as \(size) ÷ \(ratio) (B2F compresses text about \
        \(ratio):1) ÷ \(Self.rateText(compressedBytesPerSecond)) — \(rateProvenance).
        """
        if let capNote = capNote(bytes: bytes) {
            text += "\n\n" + capNote
        }
        return text
    }

    /// The clause that follows the rate in the tooltip. Every branch
    /// says where the number came from; none of them imply evidence
    /// that does not exist.
    private var rateProvenance: String {
        switch basis {
        case .measured(let gateway, _):
            return """
            your own measured throughput to \(gateway). The compression \
            ratio is still an assumption: catalog text compressed 4.2:1 in \
            testing, but fax and radar products are not text.
            """
        case .assumed(.noGateway):
            return """
            an assumed rate for a healthy 1200-baud path, because no gateway \
            is selected. Set one in Stations and the estimate uses your own \
            measured throughput instead.
            """
        case .assumed(.noSamples(let gateway)):
            return """
            an assumed rate for a healthy 1200-baud path, because no session \
            with \(gateway) has yet moved enough traffic to measure. It will \
            switch to your own throughput once one has.
            """
        case .assumed(.samplesNotFromHere(let gateway, let rate, let kilometres)):
            let sample = Self.rateText(rate)
            if let kilometres {
                return """
                an assumed rate for a healthy 1200-baud path. \(gateway) has \
                been measured at \(sample), but elsewhere — \
                \(Self.distanceText(kilometres)) from here — and RF \
                reachability does not travel with the operator, so that figure \
                is context, not a prediction.
                """
            }
            return """
            an assumed rate for a healthy 1200-baud path. \(gateway) has been \
            measured at \(sample), but those sessions carry no recorded \
            position, so they cannot be tied to where you are now.
            """
        }
    }

    /// Warns when the gateway will hang up before the request finishes.
    private func capNote(bytes: Int) -> String? {
        guard let cap = sessionCapSeconds else { return nil }
        let sessions = sessionsRequired(bytes: bytes)
        guard sessions > 1 else { return nil }
        let who = gateway ?? "This gateway"
        return """
        \(who) has never held a session longer than \(Self.durationText(cap)), \
        so this needs at least \(sessions) exchanges — the transfer resumes \
        where it left off each time.
        """
    }

    // MARK: - Formatting

    static func rateText(_ bytesPerSecond: Double) -> String {
        bytesPerSecond >= 10
            ? "\(Int(bytesPerSecond.rounded())) B/s"
            : String(format: "%.1f B/s", bytesPerSecond)
    }

    static func durationText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds < 60 { return "\(max(1, Int(seconds.rounded())))s" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 3600 ? [.minute] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "\(Int(seconds))s"
    }

    private static func distanceText(_ kilometres: Double) -> String {
        kilometres < 10
            ? String(format: "%.1f km", kilometres)
            : "\(Int(kilometres.rounded())) km"
    }
}

// MARK: - Deriving from observed link quality

extension WinlinkAirtimeEstimate {

    /// Builds an estimate for one gateway from AXTerm's own session
    /// history.
    ///
    /// Rate and cap are drawn differently on purpose. A **rate** is a
    /// property of the channel, and `WinlinkLinkQuality` is explicit
    /// that 145.030 at 1200 bd and 441.075 at 9600 bd "behave nothing
    /// alike" — so a rate is never borrowed across frequencies. A
    /// **cap** is a property of the gateway's software, so it carries
    /// across every frequency that gateway answers on.
    ///
    /// - Parameters:
    ///   - callsign: the gateway about to be worked. Empty means none.
    ///   - frequencyHz: the frequency it will be worked on. Nil falls
    ///     back to that callsign's best-evidenced link.
    ///   - quality: `WinlinkLinkQuality.summarize` output.
    static func forGateway(callsign: String,
                           frequencyHz: Int?,
                           quality: [String: WinlinkLinkQuality]) -> WinlinkAirtimeEstimate {
        let call = callsign.uppercased()
        guard !call.isEmpty else {
            return WinlinkAirtimeEstimate(basis: .assumed(.noGateway), sessionCapSeconds: nil)
        }

        let sameGateway = quality.values.filter { $0.callsign == call }

        // A handful of short sessions is not evidence of a cap — every
        // session is short when there is nothing to send. The one-minute
        // floor matches the exchange card's own cap heuristic.
        let longest = sameGateway.map(\.longestSessionSeconds).max() ?? 0
        let cap: Double? = longest > 60 ? longest : nil

        let link: WinlinkLinkQuality? = {
            if let frequencyHz {
                return quality[linkKey(callsign: call, frequencyHz: frequencyHz)]
            }
            // No frequency chosen: the link with the most measured time
            // is the best-evidenced answer available.
            return sameGateway
                .filter { $0.effectiveBytesPerSecond != nil }
                .max { $0.measuredSeconds < $1.measuredSeconds }
        }()

        guard let link, let rate = link.effectiveBytesPerSecond else {
            return WinlinkAirtimeEstimate(
                basis: .assumed(.noSamples(gateway: call)), sessionCapSeconds: cap)
        }
        guard link.appliesHere else {
            return WinlinkAirtimeEstimate(
                basis: .assumed(.samplesNotFromHere(
                    gateway: call,
                    bytesPerSecond: rate,
                    kilometres: kilometres(of: link.placement))),
                sessionCapSeconds: cap)
        }
        return WinlinkAirtimeEstimate(
            basis: .measured(gateway: call, bytesPerSecond: rate), sessionCapSeconds: cap)
    }

    private static func linkKey(callsign: String, frequencyHz: Int?) -> String {
        WinlinkLinkQuality.linkKey(callsign: callsign, frequencyHz: frequencyHz)
    }

    /// Nil for `.unknown` — "no recorded position" is a different kind
    /// of doubt from "far away", and the tooltip words them differently.
    private static func kilometres(of placement: WinlinkLinkQuality.Placement) -> Double? {
        switch placement {
        case .here: 0
        case .nearby(let kilometres): kilometres
        case .elsewhere(_, let kilometres): kilometres
        case .unknown: nil
        }
    }
}
