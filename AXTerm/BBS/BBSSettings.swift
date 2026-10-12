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
    static let ownerCommandsKey = "bbsOwnerCommands"
    static let ownerDevicesKey = "bbsOwnerDevices"
    static let ownerControlCommandsKey = "bbsOwnerControlCommands"
    static let controlRadiosKey = "bbsControlRadios"
    static let trustedCallersKey = "bbsTrustedCallers"
    static let maxUploadBytesKey = "bbsMaxUploadBytes"
    static let uploadQuotaBytesKey = "bbsUploadQuotaBytes"

    static let defaultIdleTimeout: TimeInterval = 300

    /// Where these settings live; the station's remote control keeps its
    /// log and code checker beside them.
    let defaults: UserDefaults

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
    /// Callers who may upload straight into an area that allows it, beside
    /// the operator's own callsigns, which always may (`BBSTrust`).
    @Published var trustedCallers: [String] {
        didSet { defaults.set(trustedCallers, forKey: Self.trustedCallersKey) }
    }

    @Published var acceptUploads: Bool {
        didSet { defaults.set(acceptUploads, forKey: Self.acceptUploadsKey) }
    }

    /// Lets the operator sign in from the road with a one-time code and see
    /// the station (`OWNER`, `ST`). Off by default.
    @Published var ownerCommandsEnabled: Bool {
        didSet { defaults.set(ownerCommandsEnabled, forKey: Self.ownerCommandsKey) }
    }

    /// The operator's devices that may sign in with a key (`OwnerKey`).
    /// Public keys only, so preferences are a fine place for them.
    @Published var ownerDevices: [OwnerKey.PairedDevice] {
        didSet { defaults.set(try? JSONEncoder().encode(ownerDevices), forKey: Self.ownerDevicesKey) }
    }

    /// Control commands the operator runs from the road (`OwnerControlCommand`).
    @Published var ownerControlCommands: [OwnerControlCommand] {
        didSet {
            defaults.set(try? JSONEncoder().encode(ownerControlCommands), forKey: Self.ownerControlCommandsKey)
        }
    }

    /// The radios control commands may name (`ControlRadio`).
    @Published var controlRadios: [ControlRadio] {
        didSet { defaults.set(try? JSONEncoder().encode(controlRadios), forKey: Self.controlRadiosKey) }
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

    init(defaults: UserDefaults = AppEnvironment.defaults) {
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
        self.ownerCommandsEnabled = defaults.bool(forKey: Self.ownerCommandsKey)
        self.ownerDevices = defaults.data(forKey: Self.ownerDevicesKey)
            .flatMap { try? JSONDecoder().decode([OwnerKey.PairedDevice].self, from: $0) } ?? []
        let storedCommands = OwnerControlCommand.upgradingPreset(
            defaults.data(forKey: Self.ownerControlCommandsKey)
                .flatMap { try? JSONDecoder().decode([OwnerControlCommand].self, from: $0) } ?? [])
        let storedRadios = defaults.data(forKey: Self.controlRadiosKey)
            .flatMap { try? JSONDecoder().decode([ControlRadio].self, from: $0) } ?? []
        let moved = OwnerControlCommand.movingToRadios(storedCommands, radios: storedRadios)
        self.ownerControlCommands = moved.commands
        self.controlRadios = moved.radios
        if moved.commands != storedCommands || moved.radios != storedRadios {
            defaults.set(try? JSONEncoder().encode(moved.commands), forKey: Self.ownerControlCommandsKey)
            defaults.set(try? JSONEncoder().encode(moved.radios), forKey: Self.controlRadiosKey)
        }
        self.trustedCallers = defaults.stringArray(forKey: Self.trustedCallersKey) ?? []
        let maxUpload = defaults.integer(forKey: Self.maxUploadBytesKey)
        self.maxUploadBytes = maxUpload > 0 ? maxUpload : 100 * 1024
        let quota = defaults.integer(forKey: Self.uploadQuotaBytesKey)
        self.uploadQuotaBytes = quota > 0 ? quota : 20 * 1024 * 1024
    }

    /// The address the mailbox actually answers on, given the station callsign.
    func effectiveCallsign(stationCallsign: String) -> String {
        // Newlines too: a pasted callsign often ends in one (2026-10-08).
        let own = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? stationCallsign.uppercased() : own.uppercased()
    }
}
