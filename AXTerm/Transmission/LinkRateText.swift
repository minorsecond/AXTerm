//
//  LinkRateText.swift
//  AXTerm
//
//  How a link's rate is written, everywhere in the app: bits per second,
//  the unit operators already use for a 1200-baud channel. Rates are stored
//  and computed in bytes per second; this is only the display. Winlink once
//  showed "47 B/s" beside file transfers' "333 bps", and the faster of the two
//  read as seven times slower (live test log, bug 43).
//

import Foundation

nonisolated enum LinkRateText {

    static func bytesPerSecond(_ bytesPerSecond: Double) -> String {
        bitsPerSecond(bytesPerSecond * 8)
    }

    /// For a tooltip that divides a size in bytes by the rate.
    static func withBytes(_ bytesPerSecond: Double) -> String {
        let bytes = bytesPerSecond >= 10
            ? "\(Int(bytesPerSecond.rounded()))"
            : String(format: "%.1f", bytesPerSecond)
        return "\(self.bytesPerSecond(bytesPerSecond)) (\(bytes) bytes/s)"
    }

    static func bitsPerSecond(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond < 1 {
            return String(format: "%.1f bps", bitsPerSecond)
        } else if bitsPerSecond < 1000 {
            return String(format: "%.0f bps", bitsPerSecond)
        } else if bitsPerSecond < 1_000_000 {
            return String(format: "%.1f kbps", bitsPerSecond / 1000)
        } else {
            return String(format: "%.2f Mbps", bitsPerSecond / 1_000_000)
        }
    }
}
