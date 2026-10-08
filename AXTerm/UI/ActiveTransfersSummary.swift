//
//  ActiveTransfersSummary.swift
//  AXTerm
//

import Foundation

/// What the always-visible transfer chip says.
///
/// File transfers showed their progress only on the Terminal's Transfers
/// tab, with no badge, so during a 20 KB transfer in the smoke run neither
/// station showed anything wherever the operator happened to be looking
/// (2026-10-03-1, issue 91). The chip sits with the toolbar's other status
/// pills on the Mac and in the status footer on iPhone and iPad.
nonisolated struct ActiveTransfersSummary: Equatable {
    /// Transfers still under way.
    let count: Int
    /// The file's name, or "N transfers".
    let title: String
    /// Which way a single transfer goes; nil for several.
    let direction: TransferDirection?
    /// 0 to 1, or nil while nothing has moved (waiting to be accepted).
    let fraction: Double?
    /// The chip's text.
    let label: String
    /// The chip's tooltip and accessibility label.
    let detail: String
    /// The iPhone and iPad card's second line: how much has moved and,
    /// once there is a rate, about how long is left.
    var progressLine: String? = nil

    /// "12 KB of 25 KB · about 3 min left" (park rehearsal 2026-10-08: the
    /// chip's thin bar and percent were too small to read on a phone).
    static func progressLine(moved: Int, total: Int, secondsLeft: Double?) -> String {
        let amounts = "\(ByteCount.string(moved)) of \(ByteCount.string(total))"
        guard let secondsLeft else { return amounts }
        return amounts + " · " + TimeLeftPhrase.text(seconds: secondsLeft)
    }

    static func make(_ transfers: [BulkTransfer], now: Date = Date()) -> ActiveTransfersSummary? {
        let active = transfers.filter(\.isUnderWay)
        guard let first = active.first else { return nil }
        guard active.count == 1 else {
            let total = active.reduce(0) { $0 + max(1, $1.targetBytes) }
            let moved = active.reduce(0) { $0 + min($1.bytesSent, $1.targetBytes) }
            let fraction = Double(moved) / Double(total)
            let title = "\(active.count) transfers"
            return ActiveTransfersSummary(
                count: active.count, title: title, direction: nil, fraction: fraction,
                label: "\(title) \(percent(fraction))",
                detail: "\(active.count) file transfers under way: \(percent(fraction)) of their bytes moved")
        }
        let name = first.fileName
        let station = first.destination
        let verb = first.direction == .outbound ? "Sending \(name) to \(station)"
                                                : "Receiving \(name) from \(station)"
        let fraction = first.progress
        switch first.status {
        case .pending, .awaitingAcceptance:
            return ActiveTransfersSummary(
                count: 1, title: name, direction: first.direction, fraction: nil,
                label: "\(name) waiting",
                detail: first.direction == .outbound ? "Waiting for \(station) to accept \(name)"
                                                     : "Waiting to receive \(name) from \(station)")
        case .paused:
            return ActiveTransfersSummary(
                count: 1, title: name, direction: first.direction, fraction: fraction,
                label: "\(name) paused", detail: "\(verb): paused at \(percent(fraction))")
        case .awaitingCompletion:
            return ActiveTransfersSummary(
                count: 1, title: name, direction: first.direction, fraction: fraction,
                label: "\(name) \(percent(fraction))",
                detail: "\(verb): all sent, waiting for \(station) to confirm")
        default:
            return ActiveTransfersSummary(
                count: 1, title: name, direction: first.direction, fraction: fraction,
                label: "\(name) \(percent(fraction))", detail: "\(verb): \(percent(fraction))",
                progressLine: progressLine(moved: min(first.bytesSent, first.targetBytes),
                                           total: first.targetBytes,
                                           secondsLeft: first.estimatedSecondsRemaining(now: now)))
        }
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

private extension BulkTransfer {
    var isUnderWay: Bool {
        switch status {
        case .pending, .awaitingAcceptance, .sending, .paused, .awaitingCompletion: return true
        case .completed, .cancelled, .failed: return false
        }
    }

    var targetBytes: Int { transmissionSize > 0 ? transmissionSize : fileSize }
}

/// "about 3 min left", said the same way wherever a transfer's remaining
/// time is shown.
nonisolated enum TimeLeftPhrase {
    static func text(seconds: Double) -> String {
        if seconds < 60 { return "under a minute left" }
        var hours = Int(seconds / 3600)
        var minutes = Int(((seconds - Double(hours) * 3600) / 60).rounded(.up))
        if minutes == 60 { hours += 1; minutes = 0 }
        if hours == 0 { return "about \(minutes) min left" }
        return minutes == 0 ? "about \(hours) h left" : "about \(hours) h \(minutes) min left"
    }
}
