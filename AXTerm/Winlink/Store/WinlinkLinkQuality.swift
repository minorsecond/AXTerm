import Foundation

/// Empirical link quality for one RMS gateway on one frequency, derived
/// from AXTerm's own session logs rather than from the CMS directory.
///
/// The CMS tells you a gateway exists, its distance, and its advertised
/// baud. It cannot tell you whether *you* can work it from *here* — that
/// is a property of the pair of endpoints plus terrain, antennas, and
/// whatever else is on the channel. Only observation answers it.
///
/// Two things make an observation valid, and both are qualified rather
/// than assumed:
///
/// * **Where it was taken.** RF reachability does not travel with the
///   operator. A measurement from 200 km away describes a different link,
///   so it is reported as such instead of being silently reused. See
///   `Placement`.
/// * **When it was taken.** Antennas come down, gateways go off the air,
///   and band conditions change. Age is always shown; nothing is
///   presented as current that is not.
///
/// Time and geography stay orthogonal: a stale nearby sample and a fresh
/// distant one are different kinds of doubt, and collapsing them into a
/// single score would hide which one applies.
nonisolated struct WinlinkLinkQuality: Equatable, Sendable {

    /// How far the operator is now from where these samples were taken.
    ///
    /// The thresholds are about RF, not precision: within a couple of
    /// kilometres the path is effectively the same, out to ~15 km it is
    /// usually similar over open terrain but can change completely across
    /// a ridge, and beyond that the sample describes another link.
    enum Placement: Equatable, Sendable {
        /// Taken from essentially where the operator is now.
        case here
        /// Taken nearby; the path is probably but not certainly the same.
        case nearby(kilometres: Double)
        /// Taken somewhere else. Reported for interest, never as a
        /// prediction of what will happen from here.
        case elsewhere(grid: String, kilometres: Double)
        /// The samples predate position stamping, or no position was
        /// known when they were taken.
        case unknown
    }

    /// Same path, close enough that terrain and antenna pattern have not
    /// meaningfully changed.
    static let hereRadiusKm: Double = 2
    /// Beyond this a sample is another link, not a soft version of this one.
    static let nearbyRadiusKm: Double = 15

    let callsign: String
    /// Nil for telnet sessions and for logs written before migration v8.
    let frequencyHz: Int?

    /// Sessions attempted against this link.
    var attempts: Int = 0
    /// Sessions where the gateway answered — the AX.25 link came up. The
    /// distinction that matters most in practice: a gateway that never
    /// answers is a different problem from one that answers and struggles.
    var answered: Int = 0
    /// Sessions that finished the B2F exchange without a failure.
    var completed: Int = 0

    var bytesSent: Int = 0
    var bytesReceived: Int = 0
    /// Wall-clock seconds spent in sessions that answered.
    var connectedSeconds: Double = 0
    /// Wall-clock seconds from sessions that actually recorded traffic —
    /// the denominator for goodput.
    ///
    /// Sessions with no recorded bytes are excluded so the numerator and
    /// denominator describe the same sessions. Without this, an hour of
    /// link time whose byte count was never captured (every pre-v8 failed
    /// session logged zero) divides into a handful of bytes and reports a
    /// working gateway as 0 B/s, indefinitely.
    var measuredSeconds: Double = 0

    var lastAttemptAt: Date?
    var lastAnsweredAt: Date?
    /// `WinlinkSessionLogRecord.result` of the most recent attempt.
    var lastResult: String?
    /// Longest session the gateway allowed. Some gateways enforce a cap
    /// (W0ARP-10 disconnects at ~17 minutes), which bounds how much can
    /// move in one attempt no matter how good the path is.
    var longestSessionSeconds: Double = 0

    var placement: Placement = .unknown

    // MARK: - Derived

    /// Bytes per second of payload across the link time that produced
    /// them. Nil until there is enough of both to mean anything — a
    /// two-second session that moved 40 bytes is not a 20 B/s link.
    var effectiveBytesPerSecond: Double? {
        guard measuredSeconds >= 10, bytesSent + bytesReceived > 0 else { return nil }
        return Double(bytesSent + bytesReceived) / measuredSeconds
    }

    /// Fraction of attempts the gateway answered. Nil with no attempts.
    var answerRate: Double? {
        guard attempts > 0 else { return nil }
        return Double(answered) / Double(attempts)
    }

    /// Whether these samples describe the link from where the operator is
    /// now. False for `.elsewhere` and `.unknown` — those are shown, but
    /// never as a prediction.
    var appliesHere: Bool {
        switch placement {
        case .here, .nearby: return true
        case .elsewhere, .unknown: return false
        }
    }

    /// True when the most recent attempt never got a link up.
    var lastAttemptWasSilent: Bool {
        guard let lastAttemptAt else { return false }
        guard let lastAnsweredAt else { return true }
        return lastAnsweredAt < lastAttemptAt
    }
}

// MARK: - Aggregation

extension WinlinkLinkQuality {

    /// Groups session logs into one quality summary per link.
    ///
    /// - Parameters:
    ///   - logs: session log rows, any order.
    ///   - observer: where the operator is now, for placement. Nil leaves
    ///     every link `.unknown` rather than assuming the samples are local.
    ///   - horizon: samples older than this are dropped entirely. Gateway
    ///     infrastructure is stable but not permanent; a year-old success
    ///     is not evidence about today.
    ///   - now: injected for tests.
    static func summarize(
        logs: [WinlinkSessionLogRecord],
        observer: StationLocation?,
        horizon: TimeInterval = 90 * 24 * 3600,
        now: Date = Date()
    ) -> [String: WinlinkLinkQuality] {

        var byLink = [String: WinlinkLinkQuality]()

        for log in logs {
            guard now.timeIntervalSince(log.startedAt) <= horizon else { continue }
            guard isLinkEvidence(log) else { continue }

            let key = linkKey(callsign: log.gatewayCallsign, frequencyHz: log.frequencyHz)
            var quality = byLink[key] ?? WinlinkLinkQuality(
                callsign: log.gatewayCallsign.uppercased(), frequencyHz: log.frequencyHz)

            quality.attempts += 1
            let duration = max(0, log.endedAt.timeIntervalSince(log.startedAt))

            // "Answered" is inferred from evidence of a live link rather
            // than from the result string: any byte exchanged, or any
            // failure that is not a connect failure, means the gateway
            // was there. A connect failure with no bytes is silence.
            let movedBytes = log.bytesSent + log.bytesReceived > 0
            let answered = wasAnswered(log)
            if answered {
                quality.answered += 1
                quality.connectedSeconds += duration
                if movedBytes { quality.measuredSeconds += duration }
                quality.longestSessionSeconds = max(quality.longestSessionSeconds, duration)
                if quality.lastAnsweredAt.map({ log.startedAt > $0 }) ?? true {
                    quality.lastAnsweredAt = log.startedAt
                }
            }
            if log.errorText == nil && log.result == "success" {
                quality.completed += 1
            }
            quality.bytesSent += log.bytesSent
            quality.bytesReceived += log.bytesReceived

            if quality.lastAttemptAt.map({ log.startedAt > $0 }) ?? true {
                quality.lastAttemptAt = log.startedAt
                quality.lastResult = log.result
            }

            byLink[key] = quality
        }

        // Placement is decided per link from the samples that carry a
        // position, using the *nearest* one: if the operator has ever
        // worked this gateway from here, that is the relevant evidence.
        for (key, var quality) in byLink {
            quality.placement = placement(
                for: logs.filter {
                    linkKey(callsign: $0.gatewayCallsign, frequencyHz: $0.frequencyHz) == key
                },
                observer: observer)
            byLink[key] = quality
        }
        return byLink
    }

    /// Whether a log row says anything about a gateway at all.
    ///
    /// Telnet reaches the CMS over the internet and describes no RF link;
    /// a fault on our own side (busy session, unencodable outbox) blames
    /// the gateway for something AXTerm did. Both are excluded — from
    /// this summary and from anything else derived from the log, so the
    /// rule has exactly one definition.
    static func isLinkEvidence(_ log: WinlinkSessionLogRecord) -> Bool {
        log.transport.lowercased() != "telnet" && !isLocalFault(log.result)
    }

    /// Whether the gateway was *there*, inferred from evidence rather
    /// than from the result string: any byte exchanged, or any failure
    /// that is not a connect failure, means it answered. A connect
    /// failure with no bytes is silence.
    static func wasAnswered(_ log: WinlinkSessionLogRecord) -> Bool {
        log.bytesSent + log.bytesReceived > 0 || !isConnectFailure(log.result)
    }

    /// Table key: callsign plus frequency, matching `WinlinkRMSStationRecord.id`.
    static func linkKey(callsign: String, frequencyHz: Int?) -> String {
        "\(callsign.uppercased())@\(frequencyHz ?? 0)"
    }

    /// A connect failure means the link never came up. `runExchange`
    /// prefixes exactly this text when `transport.open()` throws.
    private static func isConnectFailure(_ result: String) -> Bool {
        result.hasPrefix("connect failed")
    }

    /// Failures that happened before anything reached the air. These say
    /// nothing about the gateway and are excluded from its record
    /// entirely — not even counted as an attempt.
    private static func isLocalFault(_ result: String) -> Bool {
        let text = result.lowercased()
        return text.contains("session busy")
            || text.contains("already active")
            || text.contains("failed to encode outbound mail")
            || text.contains("an exchange is already running")
    }

    private static func placement(
        for logs: [WinlinkSessionLogRecord],
        observer: StationLocation?
    ) -> Placement {
        guard let observer else { return .unknown }

        var best: (kilometres: Double, grid: String)?
        for log in logs {
            guard let latitude = log.obsLatitude, let longitude = log.obsLongitude else { continue }
            var distance = greatCircleKm(
                lat1: observer.latitude, lon1: observer.longitude,
                lat2: latitude, lon2: longitude)

            // A grid-square position is only as good as the square. Two
            // stations in the same 6-character square can be 5 km apart,
            // so a grid-derived sample must not claim more precision than
            // the square has — pretending otherwise would report "here"
            // for a path that is not the same path.
            let precision = max(gridPrecisionKm(log.obsSource, log.obsGrid),
                                gridPrecisionKm(observer.source.rawValue, observer.gridSquare))
            distance = max(distance, precision)

            if best == nil || distance < best!.kilometres {
                best = (distance, log.obsGrid ?? "")
            }
        }

        guard let best else { return .unknown }
        if best.kilometres <= hereRadiusKm { return .here }
        if best.kilometres <= nearbyRadiusKm { return .nearby(kilometres: best.kilometres) }
        return .elsewhere(grid: best.grid, kilometres: best.kilometres)
    }

    /// Half the diagonal of the square a grid-derived position sits in —
    /// the worst-case error of calling its centre "where we were". GPS
    /// fixes carry no such penalty.
    private static func gridPrecisionKm(_ source: String?, _ grid: String?) -> Double {
        guard source == StationLocation.Source.manualGrid.rawValue else { return 0 }
        switch (grid ?? "").count {
        case 0, 1, 2: return 500   // field: 20° × 10°
        case 3, 4: return 60       // square: 2° × 1°
        default: return 3          // subsquare: 5' × 2.5', ~8 × 4.6 km
        }
    }

    /// Haversine distance in kilometres.
    static func greatCircleKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let radius = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}
