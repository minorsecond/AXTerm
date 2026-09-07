import Foundation

/// Names for the rows in the Sessions picker.
///
/// Session records are keyed by *transport*, because that is what they are:
/// an AX.25 link to DRLBBS and a NET/ROM circuit to DRLBBS have different
/// stats, different windows and different failure modes. The label, though,
/// was the destination alone — so both rendered as "DRLBBS", and an operator
/// looking at two identical rows could not tell which one they were about to
/// switch to (2026-08-31).
///
/// Qualifying is driven by collision rather than applied everywhere: a picker
/// where every row carries "· AX.25" is harder to read than one where the
/// suffix appears only when it is doing work.
nonisolated enum SessionRecordLabel {

    enum Transport: Equatable, Sendable {
        case ax25
        case ax25ViaDigi
        case netrom

        var name: String {
            switch self {
            case .ax25, .ax25ViaDigi: return "AX.25"
            case .netrom: return "NET/ROM"
            }
        }
    }

    struct Item: Equatable, Sendable {
        let id: String
        let destination: String
        let transport: Transport
        let via: [String]
        let relayDestination: String?
        let statusText: String
        /// Which radio carries the session, when the station has more than
        /// one. Nil with a single radio, and then the label says nothing
        /// about it.
        var radioName: String? = nil
    }

    /// Label for every record, keyed by record id.
    static func labels(for items: [Item]) -> [String: String] {
        // A relay already names both ends, and that is the fact the operator
        // is picking by, so it is part of the base rather than a qualifier.
        var base: [String: String] = [:]
        for item in items {
            var name = item.relayDestination.map { "\(item.destination) → \($0)" }
                ?? item.destination
            // The radio is not a disambiguator, it is where the frames go:
            // chosen when the session opened and fixed for its life. So it is
            // part of the name whenever there is more than one radio to
            // choose between, not only when two rows collide.
            if let radio = item.radioName { name += " · on \(radio)" }
            base[item.id] = name
        }

        var counts: [String: Int] = [:]
        for value in base.values { counts[value, default: 0] += 1 }

        var result: [String: String] = [:]
        for item in items {
            let name = base[item.id] ?? item.destination
            guard counts[name, default: 0] > 1 else {
                result[item.id] = name
                continue
            }
            // How this session is carried is the first real difference; the
            // digipeater path is more specific still, so prefer it.
            var qualified: String
            if item.transport == .ax25ViaDigi, !item.via.isEmpty {
                qualified = "\(name) · via \(item.via.joined(separator: ", "))"
            } else {
                qualified = "\(name) · \(item.transport.name)"
            }
            // A dead session sitting beside its live replacement looks
            // identical without this, and picking the dead one is a silent
            // dead end.
            if isClosed(item.statusText) {
                qualified += " (\(item.statusText.lowercased()))"
            }
            result[item.id] = qualified
        }

        // Two records that are still identical after qualifying — a mirrored
        // circuit beside a connect record, say — must not be presented as
        // interchangeable when they are not.
        var seen: [String: Int] = [:]
        for value in result.values { seen[value, default: 0] += 1 }
        for item in items where seen[result[item.id] ?? "", default: 0] > 1 {
            let status = item.statusText.lowercased()
            result[item.id] = "\(result[item.id] ?? item.destination) (\(status))"
        }
        return result
    }

    private static func isClosed(_ status: String) -> Bool {
        status == "Disconnected" || status == "Failed"
    }
}
