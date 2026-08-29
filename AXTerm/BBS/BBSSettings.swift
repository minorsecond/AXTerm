//
//  BBSSettings.swift
//  AXTerm
//
//  Personal mailbox settings. Follows the `WinlinkSettings` key-constant +
//  persist-on-didSet pattern.
//

import Foundation
import Combine

@MainActor
final class BBSSettings: ObservableObject {

    static let onAirKey = "bbsOnAir"
    static let callsignKey = "bbsCallsign"
    static let bannerKey = "bbsBanner"
    static let idleTimeoutKey = "bbsIdleTimeoutSeconds"
    static let stationInfoKey = "bbsStationInfo"
    static let publishHeardListKey = "bbsPublishHeardList"
    static let publishWhitePagesKey = "bbsPublishWhitePages"
    static let acceptUploadsKey = "bbsAcceptUploads"
    static let maxUploadBytesKey = "bbsMaxUploadBytes"
    static let uploadQuotaBytesKey = "bbsUploadQuotaBytes"

    static let defaultIdleTimeout: TimeInterval = 300

    private let defaults: UserDefaults

    /// Whether the mailbox answers calls.
    ///
    /// Off for a fresh install and never flipped on by anything but the
    /// operator: answering means transmitting unattended.
    @Published var onAir: Bool {
        didSet { defaults.set(onAir, forKey: Self.onAirKey) }
    }

    /// The callsign the mailbox answers on, SSID included.
    ///
    /// Kept separate from the station callsign rather than derived from it:
    /// the mailbox needs its own SSID whenever anything else on this TNC
    /// already answers to the station's — a second AXTerm, or a LinBPQ node
    /// on the same host. Empty means "use the station callsign", which is
    /// correct for the common case of one radio doing one thing.
    @Published var callsign: String {
        didSet { defaults.set(callsign, forKey: Self.callsignKey) }
    }

    /// Shown to every caller after the header. The operator's own words — and
    /// the only place this station says anything about when it is on the air,
    /// because the operator knows their hours and the app does not.
    @Published var banner: String {
        didSet { defaults.set(banner, forKey: Self.bannerKey) }
    }

    /// Drop a caller who has stopped typing. Unattended transmission should
    /// not hold a channel open because somebody wandered off.
    @Published var idleTimeout: TimeInterval {
        didSet { defaults.set(idleTimeout, forKey: Self.idleTimeoutKey) }
    }

    /// What `I` tells a caller about this station — rig, antenna, what the
    /// mailbox is for. Free text, the operator's own words.
    @Published var stationInfo: String {
        didSet { defaults.set(stationInfo, forKey: Self.stationInfoKey) }
    }

    /// Whether `J` answers with what this receiver has heard.
    ///
    /// On by default. A heard list is standard on a BBS and a mailbox that
    /// refuses one reads as broken — and the stations in it are transmitting
    /// on the same channel the caller is already listening to. It is still a
    /// statement about what this antenna reaches, so it can be turned off.
    @Published var publishHeardList: Bool {
        didSet { defaults.set(publishHeardList, forKey: Self.publishHeardListKey) }
    }

    /// Whether WP answers with the directory — names and QTHs callers
    /// registered here. The heard list's disclosure sibling.
    @Published var publishWhitePages: Bool {
        didSet { defaults.set(publishWhitePages, forKey: Self.publishWhitePagesKey) }
    }

    /// Whether callers may send files to this station.
    ///
    /// A separate decision from sharing files out, and off by default:
    /// accepting a file writes to the operator's disk on the say-so of
    /// whoever is holding a microphone.
    @Published var acceptUploads: Bool {
        didSet { defaults.set(acceptUploads, forKey: Self.acceptUploadsKey) }
    }

    /// Largest single upload. Small on purpose — 100 KB is twenty minutes of
    /// channel, and a caller who needs more can ask.
    @Published var maxUploadBytes: Int {
        didSet { defaults.set(maxUploadBytes, forKey: Self.maxUploadBytesKey) }
    }

    /// Total the upload folder may hold before uploads stop being accepted.
    @Published var uploadQuotaBytes: Int {
        didSet { defaults.set(uploadQuotaBytes, forKey: Self.uploadQuotaBytesKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.onAir = defaults.bool(forKey: Self.onAirKey)
        self.callsign = defaults.string(forKey: Self.callsignKey) ?? ""
        self.banner = defaults.string(forKey: Self.bannerKey) ?? ""
        let stored = defaults.double(forKey: Self.idleTimeoutKey)
        self.idleTimeout = stored > 0 ? stored : Self.defaultIdleTimeout
        self.stationInfo = defaults.string(forKey: Self.stationInfoKey) ?? ""
        // On for a fresh install; `object(forKey:)` distinguishes "never set"
        // from a deliberate off, which `bool(forKey:)` cannot.
        self.publishHeardList =
            defaults.object(forKey: Self.publishHeardListKey) as? Bool ?? true
        self.publishWhitePages =
            defaults.object(forKey: Self.publishWhitePagesKey) as? Bool ?? true
        self.acceptUploads = defaults.bool(forKey: Self.acceptUploadsKey)
        let maxUpload = defaults.integer(forKey: Self.maxUploadBytesKey)
        self.maxUploadBytes = maxUpload > 0 ? maxUpload : 100 * 1024
        let quota = defaults.integer(forKey: Self.uploadQuotaBytesKey)
        self.uploadQuotaBytes = quota > 0 ? quota : 20 * 1024 * 1024
    }

    /// The address the mailbox actually answers on, given the station callsign.
    func effectiveCallsign(stationCallsign: String) -> String {
        let own = callsign.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? stationCallsign.uppercased() : own.uppercased()
    }
}
