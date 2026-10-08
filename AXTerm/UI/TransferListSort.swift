import Foundation

/// The transfer list's sort columns (operator, 2026-10-07).
nonisolated enum TransferSortKey: String, ListSortKey {
    case date, name, station, size

    var title: String {
        switch self {
        case .date: return "Time"
        case .name: return "Name"
        case .station: return "Station"
        case .size: return "Size"
        }
    }

    var kind: SortKind {
        switch self {
        case .date: return .time
        case .name, .station: return .text
        case .size: return .size
        }
    }
}

extension ListSort where Key == TransferSortKey {
    func apply(_ transfers: [BulkTransfer]) -> [BulkTransfer] {
        // One not started yet has no time, and is the newest thing listed.
        let time = { (transfer: BulkTransfer) in TransferRowTime.time(of: transfer) ?? .distantFuture }
        let byDate = ListSort(key: .date, ascending: false).sorted(transfers, by: time)
        switch key {
        case .date: return sorted(transfers, by: time)
        case .name: return sorted(byDate, text: \.fileName)
        case .station: return sorted(byDate, text: \.destination)
        case .size: return sorted(byDate, by: \.fileSize)
        }
    }
}

/// Who a transfer was with and when, for its row: "To K0EPI-2 · Oct 7,
/// 2026 at 2:41 PM · 20:41 UTC".
nonisolated enum TransferRowTime {
    /// When it finished, or when it started while it runs.
    static func time(of transfer: BulkTransfer) -> Date? {
        transfer.completedAt ?? transfer.startedAt
    }

    static func line(_ transfer: BulkTransfer, timeZone: TimeZone = .current,
                     locale: Locale = .current) -> String? {
        guard let time = time(of: transfer) else { return nil }
        let who = (transfer.direction == .inbound ? "From " : "To ") + transfer.destination
        return who + " · " + DualTime.line(time, timeZone: timeZone, locale: locale)
    }
}
