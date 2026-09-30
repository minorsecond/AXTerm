import Foundation

/// The station callsign and the radios' SSIDs, kept to one rule.
///
/// The callsign under Settings › General is the licence call alone (K0EPI).
/// Each radio goes on the air as that call with its own SSID, or under a
/// callsign of its own, and `RadioProfile.resolvedCallsign(station:)` is where
/// that is decided. An SSID on the station callsign would be a second place to
/// set the same thing, and with two radios it could only be right for one of
/// them.
///
/// Pure, so the migration and the rules the settings field follows can be
/// tested without a store.
nonisolated enum StationCallsignRules {

    /// The licence call in a typed callsign: "k0epi-5 " gives "K0EPI".
    static func base(of typed: String) -> String {
        let normalized = CallsignValidator.normalize(typed)
        return normalized.components(separatedBy: "-").first ?? ""
    }

    /// Whether a typed callsign carries anything after the base, which the
    /// station callsign does not keep.
    static func hasSuffix(_ typed: String) -> Bool {
        CallsignValidator.normalize(typed).contains("-")
    }

    /// What the station callsign field says when an SSID is typed into it:
    /// only the base is kept, and where the SSID is set instead. Nil when the
    /// typed callsign has no suffix.
    ///
    /// With one radio the sidebar calls its page Connection, and its Identity
    /// section is the first thing on it.
    static func ssidGuidance(for typed: String, hasMultipleRadios: Bool) -> String? {
        let normalized = CallsignValidator.normalize(typed)
        guard hasSuffix(normalized) else { return nil }
        let base = base(of: normalized)
        let kept = base.isEmpty
            ? "This field takes your callsign without an SSID."
            : "Only \(base) is kept here."
        if hasMultipleRadios {
            return kept + " SSIDs are set per radio: open the radio under Radios and pick one under Identity."
        }
        if !base.isEmpty, let ssid = SSIDConvention.ssid(of: normalized), ssid > 0 {
            return kept + " To go on the air as \(base)-\(ssid), pick \(ssid) under Identity on the Connection page."
        }
        return kept + " Your radio's SSID is set under Identity on the Connection page."
    }

    /// The SSID a callsign carries under the station's own call, or nil when
    /// it is some other identity.
    ///
    /// A club call or a tactical alias is its own identity even when it has an
    /// SSID, so only the station's own base maps back onto the picker. Empty
    /// is SSID 0: a radio with no callsign of its own goes on the air as the
    /// bare station call.
    static func ssidUnderStation(_ callsign: String, station: String) -> Int? {
        if callsign.isEmpty { return 0 }
        guard let ssid = SSIDConvention.ssid(of: callsign) else {
            return callsign.uppercased() == station.uppercased() ? 0 : nil
        }
        let base = callsign.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        return base.uppercased() == station.uppercased() ? ssid : nil
    }

    /// Moves the SSID off a station callsign written by an older build.
    ///
    /// Older builds stored the callsign as it went on the air, SSID and all,
    /// and every radio with no callsign of its own inherited it. Those radios
    /// now get the full callsign written onto them, so nothing changes on the
    /// air, and the station keeps the base. Radios with a callsign of their
    /// own already had their address and keep it. SSID 0 is no suffix at all:
    /// the inheriting radios resolve to the base either way and are left
    /// empty.
    ///
    /// A suffix that is not an SSID (K0EPI-X) is copied onto the radios as it
    /// was, for the same reason: whatever it did on the air, it still does.
    ///
    /// Running it again finds a bare station callsign and changes nothing, so
    /// it needs no flag to run once.
    static func splitStoredStation(_ stored: String,
                                   radios: inout [RadioProfile]) -> (base: String, radiosChanged: Bool) {
        let full = CallsignValidator.normalize(stored)
        let base = base(of: full)
        guard full != base, !base.isEmpty else { return (base, false) }
        if let ssid = SSIDConvention.ssid(of: full), ssid == 0 { return (base, false) }
        let inherited = SSIDConvention.ssid(of: full).map { "\(base)-\($0)" } ?? full
        var changed = false
        for index in radios.indices
        where radios[index].callsign.trimmingCharacters(in: .whitespaces).isEmpty {
            radios[index].callsign = inherited
            changed = true
        }
        return (base, changed)
    }

    /// The primary radio's callsign as stored in `defaults`, for code that
    /// reads settings straight from UserDefaults off the main actor. The same
    /// answer as `AppSettingsStore.primaryCallsign`.
    static func storedPrimaryCallsign(defaults: UserDefaults) -> String {
        let station = base(of: defaults.string(forKey: AppSettingsStore.myCallsignKey) ?? "")
        guard let json = defaults.string(forKey: AppSettingsStore.radiosKey),
              let data = json.data(using: .utf8),
              let radios = try? JSONDecoder().decode([RadioProfile].self, from: data) else {
            return station
        }
        let active = radios.filter { !$0.archived }
        let primary = active.first { $0.enabled } ?? active.first
        return primary?.resolvedCallsign(station: station) ?? station
    }

    /// Moves the radios that operate under `old` onto `new`, SSIDs kept.
    ///
    /// A radio's SSID picker writes the whole callsign (K0EPI-5), so a
    /// corrected station callsign would otherwise leave every radio on the
    /// old one, now shown as "another callsign". A club call or a tactical
    /// name is its own identity and is not touched; neither is a radio that
    /// inherits, which follows the station by itself.
    static func rebase(_ radios: inout [RadioProfile], from old: String, to new: String) -> Bool {
        let old = base(of: old)
        let new = base(of: new)
        guard !old.isEmpty, !new.isEmpty, old != new else { return false }
        var changed = false
        for index in radios.indices {
            let own = CallsignValidator.normalize(radios[index].callsign)
            guard !own.isEmpty,
                  let ssid = ssidUnderStation(own, station: old) else { continue }
            radios[index].callsign = ssid == 0 ? new : "\(new)-\(ssid)"
            changed = true
        }
        return changed
    }
}
