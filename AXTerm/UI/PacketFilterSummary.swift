import Foundation

/// Saying out loud what the packet table is holding back.
///
/// A filter that silently drops rows turns this page into a liar, and it is
/// the one page in the app that is not an inference — every other view
/// derives its claims from these frames, so "I checked the packets and it
/// wasn't there" has to mean what it says.
///
/// Hence a summary rather than a lit-up icon: an icon says *that* something
/// is filtered, and the operator still has to open a popover to find out
/// what.
extension PacketFilters {

    var isDefault: Bool { self == PacketFilters() }

    /// Frame classes switched off, named as the table's own column names
    /// them.
    var hiddenFrameTypes: [String] {
        var hidden: [String] = []
        if !showUI { hidden.append("UI") }
        if !showI { hidden.append("I") }
        if !showS { hidden.append("S") }
        if !showU { hidden.append("U") }
        return hidden
    }

    /// True when the settings can only ever produce an empty table, whatever
    /// arrives. Worth saying differently from "nothing matched yet": one is
    /// a quiet channel and the other is a mistake in this popover.
    var admitsNothing: Bool {
        if payloadOnly { return !showI && !showUI }
        return !showUI && !showI && !showS && !showU
    }

    /// Payload-only supersedes the S and U switches — it admits I frames and
    /// UI frames carrying text, and nothing else — so those two controls stop
    /// meaning anything while it is on.
    var frameTypeSwitchesApply: Bool { !payloadOnly }

    /// One line naming every restriction in force. Nil when the table is
    /// showing everything it has.
    var restrictionSummary: String? {
        var parts: [String] = []
        if payloadOnly {
            parts.append("payload only")
            // Under payload-only the only switches still doing anything are
            // I and UI, so name those rather than the full hidden list.
            if !showI { parts.append("no I frames") }
            if !showUI { parts.append("no UI frames") }
        } else {
            let hidden = hiddenFrameTypes
            if !hidden.isEmpty {
                parts.append("no \(hidden.joined(separator: "/")) frames")
            }
        }
        if onlyPinned { parts.append("pinned only") }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{b7} ")
    }

    /// The status line under the table. `station` is the sidebar's filter,
    /// which hides rows just as effectively and belongs in the same sentence.
    func statusLine(shown: Int, total: Int, station: String?) -> String {
        var parts: [String] = []
        if shown == total && restrictionSummary == nil && station == nil {
            parts.append(total == 1 ? "1 frame" : "\(total.formatted()) frames")
        } else {
            parts.append("\(shown.formatted()) of \(total.formatted()) frames")
        }
        if let station { parts.append("from \(station)") }
        if let restrictionSummary { parts.append(restrictionSummary) }
        return parts.joined(separator: " \u{b7} ")
    }
}
