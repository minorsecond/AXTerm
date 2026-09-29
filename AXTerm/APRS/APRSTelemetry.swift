import Foundation

/// APRS telemetry: five analogue channels and eight bits, plus the messages a
/// station sends to say what they mean.
///
/// This is how anything that is not weather gets onto APRS. River and creek
/// gauges, tank and cistern levels, battery voltage and solar current, generator
/// state, repeater power, door and gate sensors — all of it arrives as
/// `T#` frames. In a grid-down week the question "is the creek still rising"
/// and the question "does the repeater have battery left" are both answered
/// here and nowhere else.
///
/// The raw frame is deliberately meaningless on its own: it carries five
/// integers between 0 and 255. What they *are* comes from three definition
/// messages the station sends occasionally — `PARM` (names), `UNIT` (units)
/// and `EQNS` (the coefficients that turn a count back into a real value).
/// Until those arrive a reading is an unlabelled number, and AXTerm says so
/// rather than inventing a name for it.
nonisolated struct APRSTelemetry: Equatable, Sendable {

    /// One `T#` frame: the sequence number and the raw counts.
    struct Frame: Hashable, Sendable {
        /// Sequence as sent. Usually a number, but the spec permits any three
        /// characters and some stations send a timestamp-like string, so it is
        /// kept verbatim rather than parsed into an Int and lost.
        var sequence: String
        /// Five analogue channels, 0…255 as transmitted.
        var analogue: [Double]
        /// Eight digital bits, most significant first as sent.
        var bits: [Bool]
    }

    /// What a station says its channels mean. Every field is optional because
    /// the three defining messages arrive separately and often not at all.
    struct Definition: Hashable, Sendable {
        /// Channel names: five analogue then eight digital, as far as sent.
        var names: [String] = []
        /// Units, same ordering.
        var units: [String] = []
        /// `a`, `b`, `c` per analogue channel for `a·v² + b·v + c`.
        var coefficients: [(a: Double, b: Double, c: Double)] = []
        /// Project or station title, from the `BITS` message's tail.
        var title: String?

        static func == (lhs: Definition, rhs: Definition) -> Bool {
            lhs.names == rhs.names && lhs.units == rhs.units && lhs.title == rhs.title
                && lhs.coefficients.count == rhs.coefficients.count
                && zip(lhs.coefficients, rhs.coefficients).allSatisfy {
                    $0.a == $1.a && $0.b == $1.b && $0.c == $1.c
                }
        }

        // Hashed on the labels only: the coefficient tuples are not Hashable
        // and two definitions that differ only in calibration are close
        // enough for a hash bucket, which equality then separates.
        func hash(into hasher: inout Hasher) {
            hasher.combine(names)
            hasher.combine(units)
            hasher.combine(title)
            hasher.combine(coefficients.count)
        }
    }

    /// One channel, ready to show: the label the station gave it, the value in
    /// its own units, and whether either of those was actually defined.
    struct Reading: Hashable, Sendable {
        var channel: Int
        var name: String?
        var unit: String?
        var value: Double
        /// False when no `EQNS` was received, so `value` is a raw count.
        var isCalibrated: Bool

        /// What to print. An uncalibrated count is shown as a count and
        /// labelled as one — a raw 137 displayed as "137 feet" would be a
        /// fabrication, and a flood gauge is the worst place to make one.
        var text: String {
            let number = value == value.rounded()
                ? String(Int(value))
                : String(format: "%.2f", value)
            if let unit, isCalibrated { return "\(number) \(unit)" }
            if isCalibrated { return number }
            return "\(number) (raw)"
        }
    }

    // MARK: - Parsing

    /// `T#seq,a1,a2,a3,a4,a5,bbbbbbbb` — the report itself.
    ///
    /// Some stations send `T#MIC` or omit the `#`; both are accepted because
    /// they are common on the air and unambiguous.
    static func parseFrame(info: Data) -> Frame? {
        guard var text = String(data: info, encoding: .ascii)
                ?? String(data: info, encoding: .utf8) else { return nil }
        guard text.hasPrefix("T#") || text.hasPrefix("T ") else { return nil }
        text = String(text.dropFirst(2))
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Sequence plus five analogue channels is the minimum worth keeping;
        // the digital byte is optional in practice.
        guard fields.count >= 6 else { return nil }

        let analogue = fields[1...5].map { Double($0) ?? 0 }
        guard fields[1...5].allSatisfy({ Double($0) != nil }) else { return nil }

        var bits: [Bool] = []
        if fields.count >= 7 {
            let raw = fields[6].prefix(8)
            if raw.allSatisfy({ $0 == "0" || $0 == "1" }) {
                bits = raw.map { $0 == "1" }
            }
        }
        return Frame(sequence: fields[0], analogue: Array(analogue), bits: bits)
    }

    /// One of the three definition messages, addressed to the reporting
    /// station itself. Returns what it defined, merged by the caller.
    ///
    /// Wire shape: the message body is `PARM.a,b,c,…`, `UNIT.a,b,c,…`,
    /// `EQNS.a,b,c,a,b,c,…` or `BITS.11111111,Title`.
    static func parseDefinition(_ body: String, into definition: inout Definition) -> Bool {
        func values(after prefix: String) -> [String]? {
            guard body.hasPrefix(prefix) else { return nil }
            return String(body.dropFirst(prefix.count))
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }

        if let parts = values(after: "PARM.") {
            definition.names = parts
            return true
        }
        if let parts = values(after: "UNIT.") {
            definition.units = parts
            return true
        }
        if let parts = values(after: "EQNS.") {
            // Three coefficients per analogue channel, in order. A short or
            // ragged list defines only the channels it covers rather than
            // being rejected outright — a partial calibration is still better
            // than none, and stations do send them.
            var coefficients: [(a: Double, b: Double, c: Double)] = []
            var index = 0
            while index + 2 < parts.count {
                guard let a = Double(parts[index]), let b = Double(parts[index + 1]),
                      let c = Double(parts[index + 2]) else { break }
                coefficients.append((a, b, c))
                index += 3
            }
            guard !coefficients.isEmpty else { return false }
            definition.coefficients = coefficients
            return true
        }
        if let parts = values(after: "BITS.") {
            if parts.count > 1 {
                definition.title = parts.dropFirst().joined(separator: ",")
                    .trimmingCharacters(in: .whitespaces)
            }
            return true
        }
        return false
    }

    // MARK: - Applying the definition

    /// Turns a frame's raw counts into labelled readings using whatever the
    /// station has defined so far.
    static func readings(_ frame: Frame, definition: Definition?) -> [Reading] {
        frame.analogue.enumerated().map { index, raw in
            var value = raw
            var calibrated = false
            if let equation = definition?.coefficients[safe: index] {
                value = equation.a * raw * raw + equation.b * raw + equation.c
                calibrated = true
            }
            return Reading(
                channel: index,
                name: definition?.names[safe: index]?.nonEmpty,
                unit: definition?.units[safe: index]?.nonEmpty,
                value: value,
                isCalibrated: calibrated)
        }
    }

    /// The eight bits, named where the station named them. Digital names
    /// follow the five analogue ones in `PARM`.
    static func bitReadings(_ frame: Frame, definition: Definition?)
        -> [(name: String?, isOn: Bool)] {
        frame.bits.enumerated().map { index, isOn in
            (definition?.names[safe: index + 5]?.nonEmpty, isOn)
        }
    }
}

nonisolated private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

nonisolated private extension String {
    /// Empty channel names are common padding in `PARM`; they mean "unused",
    /// which is an absence rather than a name of "".
    var nonEmpty: String? { isEmpty ? nil : self }
}
