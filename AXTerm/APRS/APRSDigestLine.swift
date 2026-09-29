//
//  APRSDigestLine.swift
//  AXTerm
//
//  An `APRSDigest` in words, for one line of the terminal.
//
//  Line-oriented on purpose: the console is a transcript, and a transcript
//  whose rows are different heights is no longer one. Everything that does not
//  fit on the line belongs in the tooltip, which carries the raw payload — so
//  what came off the air is always one hover away and the operator never has
//  to take this rendering on trust.
//

import Foundation

nonisolated enum APRSDigestLine {

    /// The decoded line. `observer` adds "how far, which way" when the station
    /// knows where it is; without it the coordinates stand alone rather than a
    /// distance being invented from a guess.
    /// `definition` is the sending station's own `PARM`/`UNIT`/`EQNS`/`BITS`,
    /// which is the only thing that turns a telemetry frame from five counts
    /// into readings. Nil until the station has sent one — they go out every
    /// few hours, so a fresh session often has none — and the line then says
    /// only what it actually knows.
    static func text(for digest: APRSDigest,
                     observer: GreatCircle.Point? = nil,
                     inMiles: Bool = true,
                     definition: APRSTelemetry.Definition? = nil) -> String {
        switch digest {
        case .position(let report):
            return position(report, observer: observer, inMiles: inMiles)
        case .weather(let weather):
            let parts = weather.summaryLines(inImperial: inMiles)
            return parts.isEmpty ? "Weather report" : parts.joined(separator: " · ")
        case .object(let object):
            return self.object(object, observer: observer, inMiles: inMiles)
        case .message(let inbound):
            return message(inbound)
        case .telemetry(let frame):
            return telemetry(frame, definition: definition)
        case .status(let text):
            let readable = readable(text)
            return readable.isEmpty ? "Status" : "Status: \(readable)"
        }
    }

    // MARK: - Position

    private static func position(_ r: APRSReport,
                                 observer: GreatCircle.Point?,
                                 inMiles: Bool) -> String {
        var parts = [coordinates(latitude: r.latitude, longitude: r.longitude)]
        if let away = distance(to: GreatCircle.Point(latitude: r.latitude, longitude: r.longitude),
                               from: observer, inMiles: inMiles) {
            parts.append(away)
        }
        if let motion = motion(courseDegrees: r.courseDegrees, speedKnots: r.speedKnots, inMiles: inMiles) {
            parts.append(motion)
        }
        if let feet = r.altitudeFeet {
            parts.append(altitude(feet: feet, inMiles: inMiles))
        }
        if let listing = r.frequency { parts.append(contentsOf: frequency(listing)) }
        if let reach = r.coverage { parts.append(contentsOf: coverage(reach, inMiles: inMiles)) }
        if let folded = r.commentTelemetry {
            // Raw, like a `T#` frame without its definition: these are counts
            // until the station's own `EQNS` says otherwise.
            parts.append("telemetry #\(folded.sequence)")
            if !folded.values.isEmpty {
                parts.append(folded.values.map(String.init).joined(separator: ", "))
            }
        }
        // A weather station beacons its readings inside the position report.
        let readings = r.weather?.summaryLines(inImperial: inMiles) ?? []
        parts.append(contentsOf: readings)
        if let comment = comment(r.comment) { parts.append(comment) }
        return parts.joined(separator: " · ")
    }

    private static func object(_ o: APRSObjectReport,
                               observer: GreatCircle.Point?,
                               inMiles: Bool) -> String {
        let name = o.name.trimmingCharacters(in: .whitespaces)
        // A killed object is news: it says the thing is no longer there, and a
        // line that read like any other placement would say the opposite.
        var parts = ["\(o.kind == .item ? "Item" : "Object") \(name)\(o.isLive ? "" : " (cancelled)")"]
        parts.append(coordinates(latitude: o.latitude, longitude: o.longitude))
        if let away = distance(to: GreatCircle.Point(latitude: o.latitude, longitude: o.longitude),
                               from: observer, inMiles: inMiles) {
            parts.append(away)
        }
        if let motion = motion(courseDegrees: o.courseDegrees, speedKnots: o.speedKnots, inMiles: inMiles) {
            parts.append(motion)
        }
        if let reach = o.coverage { parts.append(contentsOf: coverage(reach, inMiles: inMiles)) }
        parts.append(contentsOf: o.weather?.summaryLines(inImperial: inMiles) ?? [])
        if let comment = comment(o.comment) { parts.append(comment) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Message class

    private static func message(_ inbound: APRSMessage.Inbound) -> String {
        switch inbound {
        case .message(let addressee, let text, let number):
            let tag = number.map { " (#\($0))" } ?? ""
            return "To \(addressee): \(quoted(text))\(tag)"
        case .ack(let addressee, let number):
            return "Ack #\(number) to \(addressee)"
        case .reject(let addressee, let number):
            return "Reject #\(number) to \(addressee)"
        case .bulletin(let id, let text):
            return "Bulletin \(id): \(quoted(text))"
        case .directedQuery(let addressee, let query):
            return "Query \(query) to \(addressee)"
        case .generalQuery(let query):
            return "Query \(query) to everyone"
        }
    }

    /// A telemetry frame, named and calibrated where the station has said how.
    ///
    /// `T#217,137,140,41,0,0,00010011` is thirteen channels: five analogue
    /// counts and eight digital lines the operator wired up. What any of them
    /// mean lives in four messages the station sends every few hours — `PARM`
    /// names the channels, `UNIT` gives their units, `EQNS` carries the
    /// quadratic that turns a count into volts, `BITS` says which digital
    /// lines are in use and titles the project. Until those arrive there is
    /// nothing to say but the numbers, and `Reading.text` marks an
    /// uncalibrated one as a raw count rather than dressing it in units it has
    /// not earned.
    private static func telemetry(_ frame: APRSTelemetry.Frame,
                                  definition: APRSTelemetry.Definition?) -> String {
        var parts = ["Telemetry #\(frame.sequence)"]
        if let title = definition?.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            parts.append(title)
        }

        let analogue = APRSTelemetry.readings(frame, definition: definition)
        if definition == nil {
            // Nothing to name them with, so they stay a list of counts rather
            // than pretending each one is a channel.
            let values = analogue.map { $0.value == $0.value.rounded()
                ? String(Int($0.value)) : String(format: "%.2f", $0.value) }
            if !values.isEmpty { parts.append(values.joined(separator: ", ")) }
        } else {
            for reading in analogue {
                parts.append(reading.name.map { "\($0) \(reading.text)" } ?? reading.text)
            }
        }

        let bits = APRSTelemetry.bitReadings(frame, definition: definition)
        if bits.contains(where: { $0.name != nil }) {
            // A line the station named reads as that line. One it did not name
            // is left out rather than shown as an anonymous zero: `PARM` pads
            // unused channels with empty names, and eight bits of "channel six
            // is off" is what the raw form already said.
            for bit in bits {
                guard let name = bit.name else { continue }
                parts.append("\(name) \(bit.isOn ? "on" : "off")")
            }
        } else if !bits.isEmpty {
            parts.append("bits " + bits.map { $0.isOn ? "1" : "0" }.joined())
        }
        return parts.joined(separator: " · ")
    }

    /// What the station says about its own reach.
    ///
    /// `PHG3830` is four digits of dictionary lookup, and unpacked it answers
    /// the question an operator is actually asking when they look at a digi:
    /// nine watts, 2,560 feet above average terrain, 3 dB of gain, omni.
    ///
    /// The station's claim, not a measurement — `CoverageEstimate` is the
    /// other kind, and the two are never mixed.
    private static func coverage(_ coverage: APRSCoverage, inMiles: Bool) -> [String] {
        switch coverage {
        case .range(let miles):
            let text = DistanceDisplay.string(kilometres: Double(miles) * 1.609344,
                                              inMiles: inMiles, format: "%.0f")
            return ["\(text) claimed"]
        case .antenna(let antenna):
            var parts: [String] = []
            switch antenna.signal {
            case .transmitting(let watts):
                parts.append("\(watts) W")
            case .hearing(let strength):
                // A direction finder has no transmitter to describe; what it
                // can hear is the whole of what it is saying.
                parts.append("hears S\(strength)")
            }
            parts.append("\(altitude(feet: antenna.heightFeet, inMiles: inMiles)) HAAT")
            if antenna.gainDecibels > 0 { parts.append("\(antenna.gainDecibels) dB") }
            switch antenna.directivity {
            case .omnidirectional: parts.append("omni")
            case .beam(let bearing): parts.append("beam \(bearing)°")
            }
            if let rate = antenna.beaconsPerHour { parts.append("\(rate)/hour") }
            return parts
        }
    }

    /// The repeater listing, as an operator would read it off a card: where
    /// it is, what opens it, and which way the input sits.
    private static func frequency(_ spec: APRSFrequencySpec) -> [String] {
        var parts = [String(format: "%.3f MHz", spec.megahertz)]
        switch spec.tone {
        case .ctcss(let hertz):
            parts.append(String(format: "CTCSS %.1f", hertz))
        case .dcs(let code):
            parts.append("DCS \(code)")
        case Optional.some(.none):
            // The station said there is no tone, which is worth printing:
            // silence here and "we never said" would read the same.
            parts.append("no tone")
        case nil:
            break
        }
        if let offset = spec.offsetKilohertz, offset != 0 {
            // Signed, and in kHz: `-060` on the air is the standard 2 m
            // −600 kHz, and printing the wire units would mean nothing.
            parts.append(String(format: "%+d kHz", offset))
        }
        return parts
    }

    // MARK: - Pieces

    /// Four decimal places: about 11 m, which is finer than any APRS position
    /// and coarse enough not to imply a precision the encoding does not have.
    private static func coordinates(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }

    private static func distance(to point: GreatCircle.Point,
                                 from observer: GreatCircle.Point?,
                                 inMiles: Bool) -> String? {
        guard let observer else { return nil }
        let km = GreatCircle.kilometres(from: observer, to: point)
        let bearing = GreatCircle.bearingDegrees(from: observer, to: point)
        return DistanceDisplay.string(kilometres: km, inMiles: inMiles, format: "%.1f")
            + " " + GreatCircle.compassPoint(bearing)
    }

    /// Speed and heading, with 0 knots left out: a parked mobile reporting
    /// "0 mph at 0°" is three words saying nothing.
    private static func motion(courseDegrees: Int?, speedKnots: Int?, inMiles: Bool) -> String? {
        let course = APRSParser.validCourse(courseDegrees)
        guard let speedKnots, speedKnots > 0 else {
            return course.map { "heading \($0)°" }
        }
        let speed = inMiles
            ? String(format: "%.0f mph", Double(speedKnots) * 1.15078)
            : String(format: "%.0f km/h", Double(speedKnots) * 1.852)
        guard let course else { return speed }
        return "\(speed) at \(course)°"
    }

    private static func altitude(feet: Int, inMiles: Bool) -> String {
        inMiles
            ? "\(feet.formatted()) ft"
            : "\(Int((Double(feet) * 0.3048).rounded()).formatted()) m"
    }

    private static func comment(_ raw: String) -> String? {
        let text = readable(raw)
        return text.isEmpty ? nil : quoted(text)
    }

    /// A comment with the bytes that are not text taken out.
    ///
    /// Station comments are not always text, whatever the format says. A
    /// TM-D710 heard on 144.390 pads its status field to a fixed length with
    /// `FF`:
    ///
    ///     145.190MHz      -060<FF><FF>…×18…<FF>=
    ///
    /// Those bytes are not valid ASCII and not valid UTF-8, so decoding turns
    /// each one into U+FFFD and the line ends in a row of replacement glyphs.
    /// It is the sending radio's padding, not damage in flight — two receptions
    /// arrive byte-identical — and there is nothing in it for an operator to
    /// read.
    ///
    /// Dropped rather than drawn, and dropped only here: the parser keeps what
    /// arrived, the tooltip prints every byte as `<FF>`, and the RAW switch
    /// shows the frame as sent. Nothing is hidden, it is just not spelled out
    /// in replacement characters in the middle of a sentence.
    private static func readable(_ raw: String) -> String {
        let stripped = String(raw.unicodeScalars.filter { scalar in
            scalar != "\u{FFFD}" && !CharacterSet.controlCharacters.contains(scalar)
        })
        // The padding usually sat between two real fields, so collapse the gap
        // it leaves rather than printing the hole it came out of.
        return stripped.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func quoted(_ text: String) -> String {
        "\u{201C}\(text.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}"
    }
}
