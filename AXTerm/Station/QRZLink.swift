//
//  QRZLink.swift
//  AXTerm
//
//  The QRZ page for a callsign, worked out rather than looked up.
//
//  QRZ's public profile URLs are `qrz.com/db/<CALL>`, so the link needs no API
//  key, no subscription and no network call to build — which also means it can
//  be wrong, and is offered as "look this up" rather than presented as a fact
//  about the operator. A real directory lookup is a different thing and has a
//  seam of its own: see `CallsignDirectory`.
//

import Foundation

nonisolated enum QRZLink {

    /// The page for a callsign, or nil when the callsign is not one.
    ///
    /// The SSID goes: QRZ knows licences, and `KF0YKI-9` is one operator's
    /// ninth station, not a ninth licensee. `WIDE1-1` and the other service
    /// endpoints get nil rather than a page that will not exist.
    static func url(for callsign: String) -> URL? {
        let base = CallsignValidator.normalize(callsign).baseCallsign
        guard !base.isEmpty,
              CallsignValidator.isValidCallsign(base),
              !CallsignValidator.isServiceEndpoint(base),
              base.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return URL(string: "https://www.qrz.com/db/\(base)")
    }

    /// What to call the link in a menu or a button.
    static func title(for callsign: String) -> String {
        "Look up \(CallsignValidator.normalize(callsign).baseCallsign) on QRZ"
    }
}
