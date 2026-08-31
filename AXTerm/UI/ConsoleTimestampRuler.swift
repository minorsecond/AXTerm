import Foundation

/// Which console rows print their time, and where each row sits in the run
/// that shares one.
///
/// A busy exchange puts five or six lines inside one second, and the column
/// then repeats "2:07:49 PM" down the screen — six copies of one fact, in the
/// leftmost column, where the eye lands first.
///
/// Printing it once per run loses nothing: the timestamp renders to second
/// resolution, so the suppressed copies are the *same string*. But a blank
/// column reads as missing rather than as inherited, so the run's position is
/// part of the answer — the rows underneath are drawn as hanging from the
/// time above them rather than as rows whose time failed to appear.
///
/// Keyed on the rendered string rather than the interval between rows. Two
/// frames 0.8 s apart can land either side of a second boundary or inside
/// one, and the question here is only "does this row say something the row
/// above it did not".
nonisolated enum ConsoleTimestampRuler {

    /// Where a row sits among the rows sharing its displayed time.
    enum RunPosition: Equatable, Sendable {
        /// The only row at this time. Prints it, and hangs nothing below.
        case alone
        /// Prints the time, and rows below inherit it.
        case start
        /// Inherits the time, and more rows follow.
        case middle
        /// Inherits the time, and closes the run.
        case end

        /// Whether this row draws the timestamp itself.
        var printsTimestamp: Bool { self == .alone || self == .start }
        /// Whether a line is drawn down from the time above.
        var isContinuation: Bool { self == .middle || self == .end }
    }

    /// The position of every row, keyed by id.
    ///
    /// Call once per contiguous block that is drawn together. A day separator
    /// starts a new block, so the first row after one always prints.
    static func runPositions<Row: Identifiable>(
        _ rows: [Row],
        timestamp: (Row) -> String
    ) -> [Row.ID: RunPosition] {
        var positions: [Row.ID: RunPosition] = [:]
        let stamps = rows.map(timestamp)

        for index in rows.indices {
            let previousMatches = index > 0 && stamps[index - 1] == stamps[index]
            let nextMatches = index + 1 < rows.count && stamps[index + 1] == stamps[index]
            let position: RunPosition
            switch (previousMatches, nextMatches) {
            case (false, false): position = .alone
            case (false, true): position = .start
            case (true, true): position = .middle
            case (true, false): position = .end
            }
            positions[rows[index].id] = position
        }
        return positions
    }
}
