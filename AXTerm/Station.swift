//
//  Station.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

/// Represents a heard station for MHeard tracking
nonisolated struct Station: Identifiable, Hashable {

    let call: String
    var lastHeard: Date?
    /// Frames counted this session, from the capped in-memory list.
    var heardCount: Int
    /// Frames in the whole log, when it has been consulted.
    ///
    /// Separate from `heardCount` rather than replacing it, because the two
    /// answer different questions and a rebuild from the in-memory packets
    /// would otherwise wipe the lifetime figure every time history loaded.
    var lifetimeCount: Int?

    /// What to show an operator asking how much this station has been heard.
    var displayedCount: Int { max(lifetimeCount ?? 0, heardCount) }
    var lastVia: [String]

    /// Receptions with an empty (unrepeated) path — its transmitter reached
    /// us unaided. Counted for the life of the station list rather than kept
    /// as a flag, because "heard direct once out of two hundred" and "always
    /// direct" are different links and the ratio is the only thing that says
    /// which. Not persisted: the station list is rebuilt from the packet log
    /// at launch, so these are refilled by the same replay that fills
    /// `heardCount`.
    var directCount: Int = 0
    /// Receptions that arrived with a digipeater's callsign marked used.
    var digipeatedCount: Int = 0

    /// How far a query to this station has to travel to arrive.
    var reachAdvice: APRSReachAdvice {
        APRSReachAdvice.advise(direct: directCount, digipeated: digipeatedCount)
    }

    /// What each radio heard of this station. One station, several
    /// receivers: a frame both radios heard counts once in `heardCount` and
    /// once for each radio here.
    var perRadio: [RadioID: RadioObservation] = [:]

    struct RadioObservation: Hashable {
        var lastHeard: Date
        var heardCount: Int
        var lastVia: [String]
        /// Frames on this radio that carried an APRS payload, and frames that
        /// were connected-mode or NET/ROM. They classify the *radio*, not the
        /// station: one receiver may hear nothing but beacons while another
        /// hears nothing but sessions, and the map should draw each
        /// accordingly. See `RadioTrafficClassifier`.
        var aprsFrames: Int = 0
        var sessionFrames: Int = 0
    }

    /// The radios that have heard this station, most recently first.
    var heardOn: [RadioID] {
        perRadio.sorted { $0.value.lastHeard > $1.value.lastHeard }.map(\.key)
    }

    /// The station's most recent APRS position report, when it has beaconed
    /// one — authoritative over a callsign lookup for where to place it.
    var aprs: APRSReport?
    /// A bounded trail of recent APRS fixes (oldest → newest) for drawing a
    /// movement track. Only positions that actually moved are kept.
    var track: [APRSFix] = []

    /// The station's most recent weather reading. Held apart from `aprs`
    /// because the two are separate observations: many home stations beacon a
    /// bare position on one interval and a positionless weather report on
    /// another, so a reading must survive a position report that carries none.
    var weather: APRSWeather?
    /// When that reading was heard. A temperature from four hours ago is not
    /// the current temperature, and the UI has to be able to say so.
    var weatherHeard: Date?
    /// A bounded history of this station's readings, oldest first.
    ///
    /// Kept because the *change* in a reading carries information the reading
    /// itself does not: a barometer three millibars down over three hours is
    /// the single most actionable thing a surface station can tell you, and no
    /// snapshot can say it. Bounded so a station beaconing every two minutes
    /// for a week cannot grow without limit.
    var weatherHistory: [WeatherSample] = []

    struct WeatherSample: Hashable, Sendable {
        var timestamp: Date
        var weather: APRSWeather
    }

    /// How this station's traffic last reached the air, when the frame said
    /// so outright — off a transmitter, or off the internet through a
    /// gateway. `.radio` is the absence of a claim, not proof of one.
    var frameOrigin: APRSFrameOrigin = .radio

    /// The station's latest telemetry frame and whatever it has said the
    /// channels mean. Held separately from weather because it is arbitrary:
    /// a creek gauge, a battery bank and a repeater's power all arrive here.
    var telemetry: APRSTelemetry.Frame?
    var telemetryHeard: Date?
    var telemetryDefinition: APRSTelemetry.Definition?

    /// Channels ready to show, with the station's own names and units where
    /// it has sent them. Empty when nothing has been heard.
    var telemetryReadings: [APRSTelemetry.Reading] {
        guard let telemetry else { return [] }
        return APRSTelemetry.readings(telemetry, definition: telemetryDefinition)
    }

    /// How many readings to keep. At a typical ten-minute beacon this is
    /// about eight hours, which covers the three-hour pressure tendency with
    /// room for gaps.
    static let weatherHistoryLimit = 48

    struct APRSFix: Hashable, Sendable {
        var latitude: Double
        var longitude: Double
        var timestamp: Date
    }

    var id: String { call }

    init(call: String, lastHeard: Date? = nil, heardCount: Int = 0, lastVia: [String] = []) {
        self.call = call
        self.lastHeard = lastHeard
        self.heardCount = heardCount
        self.lastVia = lastVia
    }

    var subtitle: String {
        var parts: [String] = []
        // The whole log where it is known. The in-memory list is capped at
        // 5,000 frames, so on a busy channel this row was counting the last
        // few hours and reading as a total.
        let shown = displayedCount
        parts.append("\(shown.formatted()) pkt\(shown == 1 ? "" : "s")")
        if let date = lastHeard {
            parts.append(TimeDisplay.timeString(date))
        }
        return parts.joined(separator: " | ")
    }

    var lastViaDisplay: String {
        guard !lastVia.isEmpty else { return "" }
        return lastVia.joined(separator: ", ")
    }
}
