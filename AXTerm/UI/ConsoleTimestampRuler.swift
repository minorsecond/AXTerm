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
/// Keyed on the second the time falls in, never the interval between rows.
/// Two frames 0.8 s apart can land either side of a second boundary or inside
/// one, and the question here is only "does this row say something the row
/// above it did not". The time prints to the second, so the same second is
/// the same printed time.
nonisolated enum ConsoleTimestampRuler {

    /// Where a row sits among the rows sharing its displayed time.
    enum RunPosition: Hashable, Sendable {
        /// The only row at this time. Prints it, and hangs nothing below.
        case alone
        /// Prints the time, and rows below inherit it.
        case start
        /// Inherits the time, and more rows follow.
        case middle
        /// Inherits the time, and closes the run.
        case end

        /// Whether this row prints the timestamp at full strength.
        var printsTimestamp: Bool { self == .alone || self == .start }
        /// Whether this row's time repeats the row above, and so is dimmed.
        var isContinuation: Bool { self == .middle || self == .end }
    }

    /// The position of every row, keyed by id.
    ///
    /// Call once per contiguous block that is drawn together. A day separator
    /// starts a new block, so the first row after one always prints.
    static func runPositions<Row: Identifiable, Key: Equatable>(
        _ rows: [Row],
        timestamp: (Row) -> Key
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

    /// The whole second a row's time falls in, which is what its printed
    /// time shows. The console keys runs by this rather than by formatting
    /// every row's time on each rebuild: on a busy channel that was a date
    /// format per row per new line, twice over, and a steady cost while
    /// scrolling (2026-10-10).
    static func secondKey(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded(.down))
    }

    /// Every block's positions in one map, each block run on its own.
    ///
    /// For the day-separated console, which computes this when its lines
    /// change. Working it out per section inside the view body formatted every
    /// row's time again on each render, including each frame of a sidebar
    /// resize.
    static func runPositions<Row: Identifiable, Key: Equatable>(
        blocks: [[Row]],
        timestamp: (Row) -> Key
    ) -> [Row.ID: RunPosition] {
        var positions: [Row.ID: RunPosition] = [:]
        for block in blocks {
            positions.merge(runPositions(block, timestamp: timestamp)) { _, block in block }
        }
        return positions
    }
}
