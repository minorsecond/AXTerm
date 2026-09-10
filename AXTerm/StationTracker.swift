//
//  StationTracker.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

nonisolated struct StationTracker {
    private(set) var stations: [Station] = []
    private var stationIndex: [String: Int] = [:]

    /// The path a packet was actually HEARD over: the digipeaters whose H-bit
    /// is set, i.e. whose transmitter produced the copy that reached our
    /// antenna. Empty means we heard the station's own transmitter directly —
    /// even when a via path is listed but not yet acted on.
    static func heardVia(_ packet: Packet) -> [String] {
        packet.via.filter { $0.repeated }.map { $0.display }
    }

    #if DEBUG
    /// Opt-in APRS diagnostic. Run with `AXTERM_APRS_TRACE=1` in the scheme's
    /// environment, switch the radio to 144.390, and watch the console: one
    /// line per UI frame showing the destination, the info bytes, and whether
    /// the position parser accepted it — so we can see WHY a station falls back
    /// to a licence address instead of its beaconed fix.
    nonisolated(unsafe) private static let aprsTraceEnabled =
        ProcessInfo.processInfo.environment["AXTERM_APRS_TRACE"] == "1"

    static func aprsTrace(_ packet: Packet) {
        guard aprsTraceEnabled, packet.frameType == .ui else { return }
        let info = [UInt8](packet.info)
        let ascii = String(info.prefix(48).map {
            (32...126).contains($0) ? Character(UnicodeScalar($0)) : "."
        })
        let hex = info.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " ")
        let dest = packet.to?.call ?? "?"
        let dti = info.first.map { String(format: "0x%02x", $0) } ?? "-"
        let parsed = APRSParser.parse(destination: dest, info: packet.info)
        let outcome = parsed.map {
            "OK \($0.kind) \(String(format: "%.4f,%.4f", $0.latitude, $0.longitude)) sym=\($0.symbolTable)\($0.symbolCode)"
        } ?? "NO POSITION"
        print("[APRSTRACE] from=\(packet.from?.display ?? "?") dest=\(dest) "
            + "infoLen=\(info.count) dti=\(dti) ascii=\"\(ascii)\" hex=[\(hex)] => \(outcome)")
    }
    #endif

    /// Folds in lifetime totals read from the log.
    ///
    /// Applied to stations already listed rather than adding rows for every
    /// callsign ever heard: the sidebar lists what is on the air now, and
    /// turning it into a historical roster is a different feature. This only
    /// corrects the number beside a station that is already there.
    mutating func applyLifetimeCounts(_ counts: [String: Int]) {
        for index in stations.indices {
            if let lifetime = counts[stations[index].call.uppercased()] {
                stations[index].lifetimeCount = lifetime
            }
        }
    }

    /// Attach an APRS position from this packet, if it carries one. A fix is
    /// added to the trail only when the station has actually moved, so a fixed
    /// station beaconing every few minutes does not grow an endless track.
    /// Files how this frame reached the air, when it says so outright.
    ///
    /// Only ever upgraded away from `.radio` by a frame that carries the
    /// claim: a station that gates some traffic and beacons the rest should
    /// read as gated, because that is the fact worth knowing. A later plain
    /// frame does not clear it — absence of a marker is not evidence of RF.
    static func applyOrigin(_ station: inout Station, packet: Packet) {
        guard !packet.info.isEmpty else { return }
        let origin = APRSFrameOrigin.classify(info: packet.info,
                                              via: packet.via.map(\.display))
        if origin.isFromInternet { station.frameOrigin = origin }
    }

    static func applyAPRS(_ station: inout Station, packet: Packet) {
        #if DEBUG
        aprsTrace(packet)
        #endif
        guard !packet.info.isEmpty else { return }
        guard let report = APRSParser.parse(destination: packet.to?.call ?? "", info: packet.info)
        else {
            // No position — but a positionless weather report is still this
            // station's weather, and dropping it would lose the reading of
            // every station that beacons its fix and its sensors separately.
            if let weather = APRSParser.parseWeather(info: packet.info) {
                recordWeather(&station, weather, at: packet.timestamp)
            }
            return
        }
        station.aprs = report
        if let weather = report.weather {
            recordWeather(&station, weather, at: packet.timestamp)
        }
        let fix = Station.APRSFix(latitude: report.latitude, longitude: report.longitude,
                                  timestamp: packet.timestamp)
        if let last = station.track.last,
           abs(last.latitude - fix.latitude) < 1e-5, abs(last.longitude - fix.longitude) < 1e-5 {
            station.track[station.track.count - 1].timestamp = fix.timestamp
        } else {
            station.track.append(fix)
            if station.track.count > 30 { station.track.removeFirst(station.track.count - 30) }
        }
    }

    /// Stores a reading as the current one and appends it to the history.
    ///
    /// A repeat of the identical reading at a new time still counts: the gap
    /// between beacons is what makes a tendency measurable, and dropping
    /// duplicates would make a station whose pressure is steady look as
    /// though it had stopped reporting.
    static func recordWeather(_ station: inout Station, _ weather: APRSWeather, at when: Date) {
        station.weather = weather
        station.weatherHeard = when
        // Out-of-order arrivals happen on a digipeated channel. Keep the
        // history sorted rather than trusting arrival order, because every
        // trend read off it assumes oldest first.
        station.weatherHistory.append(Station.WeatherSample(timestamp: when, weather: weather))
        if station.weatherHistory.count > 1,
           station.weatherHistory[station.weatherHistory.count - 2].timestamp > when {
            station.weatherHistory.sort { $0.timestamp < $1.timestamp }
        }
        if station.weatherHistory.count > Station.weatherHistoryLimit {
            station.weatherHistory.removeFirst(
                station.weatherHistory.count - Station.weatherHistoryLimit)
        }
    }

    /// Files a telemetry frame or one of the three messages that define what
    /// its channels mean.
    ///
    /// The definitions are addressed *to the reporting station itself*, which
    /// is how a station publishes its own calibration. They arrive rarely and
    /// out of band, so they are merged into whatever is already known rather
    /// than replacing it.
    static func applyTelemetry(_ station: inout Station, packet: Packet) {
        guard !packet.info.isEmpty else { return }
        if let frame = APRSTelemetry.parseFrame(info: packet.info) {
            station.telemetry = frame
            station.telemetryHeard = packet.timestamp
            return
        }
        guard case .message(let addressee, let text, _)? =
                APRSMessage.parse(info: packet.info) else { return }
        // Only the station's own definitions describe its own channels.
        // Someone else's PARM addressed elsewhere says nothing about this one.
        guard CallsignQuery.normalize(addressee)
                == CallsignQuery.normalize(station.call) else { return }
        var definition = station.telemetryDefinition ?? APRSTelemetry.Definition()
        if APRSTelemetry.parseDefinition(text, into: &definition) {
            station.telemetryDefinition = definition
        }
    }

    mutating func update(with packet: Packet) {
        guard let from = packet.from else { return }
        let call = from.display
        let radio = packet.radioID ?? .primary
        let via = Self.heardVia(packet)

        if let index = stationIndex[call] {
            stations[index].lastHeard = packet.timestamp
            stations[index].heardCount += 1
            // Always overwrite — including with empty. The old code only wrote
            // non-empty paths, so a station once heard via a digi showed
            // "Via DRLNOD, FNKTWN" forever, even while an entire direct
            // session was proving we hear its own transmitter (sidebar said
            // via-digi while the session correctly said direct).
            stations[index].lastVia = via
            // `heardVia` keeps only hops marked used, so an empty path here
            // means nothing repeated this frame — it came straight off the
            // station's own transmitter.
            if via.isEmpty { stations[index].directCount += 1 }
            else { stations[index].digipeatedCount += 1 }
            Self.note(&stations[index], radio: radio, at: packet.timestamp, via: via, packet: packet)
            Self.applyAPRS(&stations[index], packet: packet)
            Self.applyTelemetry(&stations[index], packet: packet)
            Self.applyOrigin(&stations[index], packet: packet)
        } else {
            var station = Station(
                call: call,
                lastHeard: packet.timestamp,
                heardCount: 1,
                lastVia: via
            )
            if via.isEmpty { station.directCount = 1 } else { station.digipeatedCount = 1 }
            Self.note(&station, radio: radio, at: packet.timestamp, via: via, packet: packet)
            Self.applyAPRS(&station, packet: packet)
            Self.applyTelemetry(&station, packet: packet)
            Self.applyOrigin(&station, packet: packet)
            stations.append(station)
            stationIndex[call] = stations.count - 1
        }

        sortStations()
    }

    /// Another radio heard a frame this tracker already counted — the same
    /// transmission, a second receiver. The station's count does not move;
    /// which radios can hear it does.
    mutating func noteHeard(_ call: String, on radio: RadioID, at when: Date,
                            via: [String], packet: Packet) {
        guard let index = stationIndex[call] else { return }
        Self.note(&stations[index], radio: radio, at: when, via: via, packet: packet)
    }

    /// What a frame proves about the *radio* that heard it. See
    /// `RadioTrafficFamily`.
    ///
    /// Three guards, each of which this got wrong at least once:
    ///
    /// * **APRS only ever rides in a UI frame with PID 0xF0.** Without that
    ///   check, an I-frame inside a connected-mode session counted as APRS
    ///   evidence, and a packet-only radio was badged "APRS · AX.25" for
    ///   traffic that was nothing of the sort. NET/ROM is PID 0xCF and is
    ///   excluded by the same test.
    /// * **A bare general query is not evidence.** `APRSMessage.parse` accepts
    ///   any text beginning with `?` as an APRS query, and `?` is the
    ///   universal help command at a node prompt — so every operator asking a
    ///   BBS for help was voting the channel APRS.
    /// * A plain UI frame that parses as nothing proves nothing either way:
    ///   APRS and a NET/ROM NODES broadcast both ride in one.
    static func trafficEvidence(_ packet: Packet) -> (aprs: Bool, session: Bool) {
        let session = RadioTrafficClassifier.isSessionEvidence(packet.frameType)
        guard !packet.info.isEmpty,
              packet.frameType == .ui,
              packet.pid == 0xF0 else { return (false, session) }

        if APRSParser.parse(destination: packet.to?.call ?? "", info: packet.info) != nil
            || APRSParser.parseWeather(info: packet.info) != nil
            || APRSObjectReport.parse(info: packet.info) != nil {
            return (true, session)
        }
        // A message or bulletin counts; a bare `?…` query does not.
        switch APRSMessage.parse(info: packet.info) {
        case .message, .ack, .reject, .bulletin, .directedQuery:
            return (true, session)
        case .generalQuery, .none:
            return (false, session)
        }
    }

    private static func note(_ station: inout Station, radio: RadioID, at when: Date,
                             via: [String], packet: Packet) {
        let (isAPRS, isSession) = trafficEvidence(packet)

        if var observation = station.perRadio[radio] {
            observation.lastHeard = max(observation.lastHeard, when)
            observation.heardCount += 1
            observation.lastVia = via
            if isAPRS { observation.aprsFrames += 1 }
            if isSession { observation.sessionFrames += 1 }
            station.perRadio[radio] = observation
        } else {
            station.perRadio[radio] = Station.RadioObservation(
                lastHeard: when, heardCount: 1, lastVia: via,
                aprsFrames: isAPRS ? 1 : 0, sessionFrames: isSession ? 1 : 0)
        }
    }

    mutating func reset() {
        stations.removeAll()
        stationIndex.removeAll()
    }

    mutating func rebuild(from packets: [Packet]) {
        stations.removeAll(keepingCapacity: true)
        stationIndex.removeAll(keepingCapacity: true)

        struct Aggregation {
            var lastHeard: Date?
            var heardCount: Int = 0
            var lastVia: [String] = []
            var perRadio: [RadioID: Station.RadioObservation] = [:]
            var direct: Int = 0
            var digipeated: Int = 0
        }

        var aggregates: [String: Aggregation] = [:]

        for packet in packets where !packet.isOwnEcho {
            guard let from = packet.from else { continue }
            let call = from.display
            var aggregate = aggregates[call, default: Aggregation()]
            aggregate.heardCount += 1
            // Counted here as well as in `update(with:)` for the reason the
            // comment below gives: a rebuild that left these at zero would
            // report every station as never heard, and the reach advice would
            // warn about the whole channel until the next frame arrived.
            if Self.heardVia(packet).isEmpty { aggregate.direct += 1 }
            else { aggregate.digipeated += 1 }
            let radio = packet.radioID ?? .primary
            // Count the traffic evidence here too. A rebuild happens on a
            // radio reconnect, a replay, or a lifetime-count refresh, and
            // leaving these at zero wiped every radio's APRS/AX.25
            // classification — which silently un-grouped the whole map layer
            // sidebar and dropped both badges. Same failure the position
            // re-apply below exists to prevent.
            let (isAPRS, isSession) = Self.trafficEvidence(packet)
            if var observation = aggregate.perRadio[radio] {
                observation.lastHeard = max(observation.lastHeard, packet.timestamp)
                observation.heardCount += 1
                observation.lastVia = Self.heardVia(packet)
                if isAPRS { observation.aprsFrames += 1 }
                if isSession { observation.sessionFrames += 1 }
                aggregate.perRadio[radio] = observation
            } else {
                aggregate.perRadio[radio] = Station.RadioObservation(
                    lastHeard: packet.timestamp, heardCount: 1, lastVia: Self.heardVia(packet),
                    aprsFrames: isAPRS ? 1 : 0, sessionFrames: isSession ? 1 : 0)
            }
            if let currentLastHeard = aggregate.lastHeard {
                if packet.timestamp >= currentLastHeard {
                    aggregate.lastHeard = packet.timestamp
                    aggregate.lastVia = Self.heardVia(packet)
                }
            } else {
                aggregate.lastHeard = packet.timestamp
                aggregate.lastVia = Self.heardVia(packet)
            }
            aggregates[call] = aggregate
        }

        stations = aggregates.map { call, aggregate in
            var station = Station(
                call: call,
                lastHeard: aggregate.lastHeard,
                heardCount: aggregate.heardCount,
                lastVia: aggregate.lastVia
            )
            station.perRadio = aggregate.perRadio
            station.directCount = aggregate.direct
            station.digipeatedCount = aggregate.digipeated
            return station
        }
        sortStations()

        // Re-apply APRS positions from the packet history, in time order, so a
        // rebuild keeps the transmitted fixes and movement tracks that
        // update(with:) accrues live. Without this, any bulk rebuild — a radio
        // reconnecting, a replay, a lifetime-count refresh — silently dropped
        // every station back to its licence/registry placement and erased its
        // symbol. Filtered to UI frames with a payload first, so only the few
        // frames that could carry a position are sorted and parsed.
        let positionPackets = packets
            .filter { !$0.isOwnEcho && $0.frameType == .ui && !$0.info.isEmpty }
            .sorted { $0.timestamp < $1.timestamp }
        for packet in positionPackets {
            guard let call = packet.from?.display, let index = stationIndex[call] else { continue }
            Self.applyAPRS(&stations[index], packet: packet)
            // Telemetry rides the same replay for the same reason, and the
            // definitions matter more than the frame: a station broadcasts
            // PARM/UNIT/EQNS roughly hourly and we hear a fraction of those,
            // so a rebuild that dropped them left every channel reading
            // "185 (raw)" for hours with the calibration sitting unread in
            // the packet history (SIMLA, 2026-09-10).
            Self.applyTelemetry(&stations[index], packet: packet)
            Self.applyOrigin(&stations[index], packet: packet)
        }
    }

    func heardCount(for call: String) -> Int? {
        guard let index = stationIndex[call] else { return nil }
        return stations[index].heardCount
    }

    private mutating func sortStations() {
        stations.sort {
            let leftDate = $0.lastHeard ?? .distantPast
            let rightDate = $1.lastHeard ?? .distantPast
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return $0.call.localizedCaseInsensitiveCompare($1.call) == .orderedAscending
        }
        stationIndex.removeAll()
        for (index, station) in stations.enumerated() {
            stationIndex[station.call] = index
        }
    }
}
