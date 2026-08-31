import Foundation

/// Which console rows print their time.
///
/// A busy exchange puts five or six lines inside one second, and the column
/// then repeats "1:31:28 PM" down the screen — six copies of one fact, in
/// the leftmost column, where the eye lands first.
///
/// Printing it once per second loses nothing. The timestamp is rendered to
/// second resolution, so the copies are the *same string*: this suppresses a
/// repetition, not information. Rows that stay silent keep the column's
/// width so the text beside them stays aligned, and carry the time as a
/// tooltip for anyone who wants it back.
///
/// Deliberately keyed on the rendered string rather than on the interval
/// between rows. Two frames 0.8 s apart can land either side of a second
/// boundary or inside one, and the question here is only "does this row say
/// something the row above it did not".
nonisolated enum ConsoleTimestampRuler {

    /// The rows that should print their timestamp: the first of each run of
    /// rows sharing one displayed time.
    ///
    /// Call once per contiguous block that is drawn together. A day separator
    /// starts a new block, so the first row after one always prints.
    static func printingRows<Row: Identifiable>(
        _ rows: [Row],
        timestamp: (Row) -> String
    ) -> Set<Row.ID> {
        var printing = Set<Row.ID>()
        var previous: String?
        for row in rows {
            let stamp = timestamp(row)
            if stamp != previous {
                printing.insert(row.id)
                previous = stamp
            }
        }
        return printing
    }
}
