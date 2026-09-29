import Foundation

/// Byte counts, formatted for display.
///
/// Exists because `ByteCountFormatter` spells zero out as words:
/// `allowsNonnumericFormatting` defaults to `true`, so a count of 0 comes
/// back as "Zero KB" rather than "0 KB". On a chart axis that is plainly
/// wrong — every other label on the axis is a number — and in a transfer
/// list an empty file reads as "Zero bytes".
///
/// One place, so the setting cannot be remembered at some call sites and
/// forgotten at others.
nonisolated enum ByteCount {

    /// A file-style byte count: "0 bytes", "408 bytes", "3 KB", "54 KB".
    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }

    static func string(_ bytes: Int) -> String {
        string(Int64(bytes))
    }

    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}
