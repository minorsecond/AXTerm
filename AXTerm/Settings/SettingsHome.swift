//
//  SettingsHome.swift
//  AXTerm
//
//  Where each setting lives. One page and one section per setting, and the
//  page does not change when a second radio is added. The deep links read
//  this table, so "open the setting" and "where the setting is" cannot drift
//  apart, and a test checks that nothing is registered twice.
//
//  A radio's page holds its hardware and identity. What the radio does on
//  the air (its APRS path and position beacon, its packet services,
//  digipeater and ID beacon) is on the service page for its channel, in a
//  section of its own.
//

import Foundation

/// A section a deep link can land on. The page puts `.id(section)` on the
/// section and scrolls to it when `SettingsRouter.highlightSection` names it.
nonisolated enum SettingsSection: String, Hashable, Sendable, CaseIterable {
    // General
    case stationIdentity
    case stationPosition
    case display
    case online
    case system

    // A radio's page, top to bottom
    case radioConnection
    /// A TNC4's receive audio: its level meter, input gain and twist.
    case radioReceiveAudio
    case radioIdentity
    case radioChannel
    case radioTiming

    // Packet Node
    case netRomNode
    /// One set of sections per packet radio: its services, digipeater and
    /// ID beacon. A link that names a radio lands on that radio's sections.
    case packetRadios
    case ping
    case linkLayer
    case adaptiveTransmission
    case axdpProtocol
    case fileTransfer

    // APRS
    case aprsMessaging
    /// One section per APRS radio: its path and position beacon. A link
    /// that names a radio lands on that radio's section.
    case aprsRadios

    /// The page this section is on.
    var tab: SettingsTab {
        switch self {
        case .stationIdentity, .stationPosition, .display, .online, .system:
            return .general
        case .radioConnection, .radioReceiveAudio, .radioIdentity, .radioChannel, .radioTiming:
            return .radios
        case .netRomNode, .packetRadios, .ping, .linkLayer, .adaptiveTransmission, .axdpProtocol,
             .fileTransfer:
            return .packetNode
        case .aprsMessaging, .aprsRadios:
            return .aprs
        }
    }
}

/// The one home of every setting the redesign touched.
///
/// Settings are named by the key they are stored under (`AppSettingsStore`'s
/// key constants) or, for a radio's own settings, `radio.` and the
/// `RadioProfile` field. Moving a control means changing its entry here; the
/// stored key never changes.
enum SettingsHome {

    struct Entry: Sendable {
        let setting: String
        let section: SettingsSection
    }

    static let entries: [Entry] = station + radio + packetNode + aprs

    static func section(of setting: String) -> SettingsSection? {
        entries.first { $0.setting == setting }?.section
    }

    /// A radio setting whose home depends on the radio's channel.
    struct ChannelEntry: Sendable {
        let setting: String
        let aprs: SettingsSection
        let packet: SettingsSection

        func section(on channel: RadioChannel) -> SettingsSection {
            channel == .aprs ? aprs : packet
        }
    }

    /// The beacon's switch and interval. One stored beacon per radio, sent
    /// as a position beacon on an APRS channel and an ID beacon on a packet
    /// channel, so these two have a home on each service page and appear
    /// in the radio's section on whichever page its channel names. They
    /// are kept out of `entries`, which holds settings with one home.
    static let byChannel: [ChannelEntry] = [
        ChannelEntry(setting: "radio.beacon.enabled", aprs: .aprsRadios, packet: .packetRadios),
        ChannelEntry(setting: "radio.beacon.intervalMinutes", aprs: .aprsRadios, packet: .packetRadios),
    ]

    /// Where a setting is for a radio on `channel`: its one home, or the
    /// channel's home for a setting in `byChannel`.
    static func section(of setting: String, channel: RadioChannel) -> SettingsSection? {
        byChannel.first { $0.setting == setting }?.section(on: channel) ?? section(of: setting)
    }

    static func settings(on tab: SettingsTab) -> [String] {
        entries.filter { $0.section.tab == tab }.map(\.setting)
    }

    // MARK: General

    private static let station: [Entry] = [
        Entry(setting: AppSettingsStore.myCallsignKey, section: .stationIdentity),
        Entry(setting: StationPositionKeys.useDeviceLocation, section: .stationPosition),
        Entry(setting: StationPositionKeys.manualLatitude, section: .stationPosition),
        Entry(setting: StationPositionKeys.manualLongitude, section: .stationPosition),
        // The one grid square. Winlink reads it and shows it; only General edits it.
        Entry(setting: WinlinkSettings.gridSquareKey, section: .stationPosition),
        Entry(setting: TimeDisplay.formatKey, section: .display),
        Entry(setting: AppSettingsStore.consoleSeparatorsKey, section: .display),
        Entry(setting: AppSettingsStore.rawSeparatorsKey, section: .display),
        Entry(setting: AppSettingsStore.terminalFontSizeKey, section: .display),
        Entry(setting: WinlinkSettings.distanceUnitIsMilesKey, section: .display),
        Entry(setting: WinlinkSettings.heightUnitIsFeetKey, section: .display),
        Entry(setting: WinlinkSettings.callsignLookupEnabledKey, section: .online),
        Entry(setting: AppSettingsStore.autoConnectKey, section: .system),
        Entry(setting: AppSettingsStore.runInMenuBarKey, section: .system),
        Entry(setting: AppSettingsStore.launchAtLoginKey, section: .system),
        Entry(setting: AppSettingsStore.keepAwakePolicyKey, section: .system),
    ]

    // MARK: A radio's page

    private static let radio: [Entry] = [
        Entry(setting: "radio.name", section: .radioConnection),
        Entry(setting: "radio.enabled", section: .radioConnection),
        Entry(setting: "radio.kind", section: .radioConnection),
        Entry(setting: "radio.host", section: .radioConnection),
        Entry(setting: "radio.port", section: .radioConnection),
        Entry(setting: "radio.serialDevicePath", section: .radioConnection),
        Entry(setting: "radio.blePeripheralUUID", section: .radioConnection),
        Entry(setting: "radio.mobilinkdEnabled", section: .radioConnection),
        Entry(setting: "radio.tnc4", section: .radioConnection),
        Entry(setting: "radio.tnc4.inputGain", section: .radioReceiveAudio),
        Entry(setting: "radio.tnc4.inputTwist", section: .radioReceiveAudio),
        Entry(setting: "radio.modem", section: .radioConnection),
        Entry(setting: "radio.maxTransmitSeconds", section: .radioConnection),
        Entry(setting: "radio.callsign", section: .radioIdentity),
        Entry(setting: "radio.aprsEnabled", section: .radioChannel),
        // Set by the channel, which switches the beacon's kind with it.
        Entry(setting: "radio.beacon.kind", section: .radioChannel),
        Entry(setting: "radio.txDelayMs", section: .radioTiming),
        Entry(setting: "radio.persistence", section: .radioTiming),
        Entry(setting: "radio.slotTimeMs", section: .radioTiming),
        Entry(setting: "radio.txTailMs", section: .radioTiming),
        Entry(setting: "radio.sendsKISSTiming", section: .radioTiming),
    ]

    // MARK: Packet Node

    private static let packetNode: [Entry] = [
        Entry(setting: AppSettingsStore.netRomAcceptInboundKey, section: .netRomNode),
        Entry(setting: AppSettingsStore.netRomNodeAliasKey, section: .netRomNode),
        Entry(setting: AppSettingsStore.netRomAdvertiseKey, section: .netRomNode),
        Entry(setting: AppSettingsStore.netRomNodeIdentityKey, section: .netRomNode),
        Entry(setting: AppSettingsStore.netRomBroadcastMinutesKey, section: .netRomNode),
        Entry(setting: AppSettingsStore.netRomForwardingKey, section: .netRomNode),
        Entry(setting: AppSettingsStore.autoRouteMaxChainLengthKey, section: .netRomNode),
        // Each packet radio's own sections.
        Entry(setting: "radio.announcesNode", section: .packetRadios),
        Entry(setting: "radio.netRomAlias", section: .packetRadios),
        Entry(setting: "radio.pings", section: .packetRadios),
        Entry(setting: "radio.answersMailbox", section: .packetRadios),
        Entry(setting: "radio.digi.enabled", section: .packetRadios),
        Entry(setting: "radio.digi.fillIn", section: .packetRadios),
        Entry(setting: "radio.digi.wideAreaMaxHops", section: .packetRadios),
        Entry(setting: "radio.digi.aliases", section: .packetRadios),
        Entry(setting: "radio.digi.dupeSeconds", section: .packetRadios),
        Entry(setting: "radio.beacon.text", section: .packetRadios),
        Entry(setting: "radio.beacon.path", section: .packetRadios),
        Entry(setting: AppSettingsStore.pingEnabledKey, section: .ping),
        Entry(setting: AppSettingsStore.pingWindowStartKey, section: .ping),
        Entry(setting: AppSettingsStore.pingWindowEndKey, section: .ping),
        Entry(setting: AppSettingsStore.pingMaxPerHourKey, section: .ping),
        Entry(setting: AppSettingsStore.pingSpacingKey, section: .ping),
        Entry(setting: AppSettingsStore.pingBoxCooldownKey, section: .ping),
        Entry(setting: AppSettingsStore.pingCooldownKey, section: .ping),
        Entry(setting: AppSettingsStore.pingProbeCalledKey, section: .ping),
        Entry(setting: AppSettingsStore.ax25T1TimeoutSecondsKey, section: .linkLayer),
        Entry(setting: AppSettingsStore.ax25NegotiateV22Key, section: .linkLayer),
        Entry(setting: "adaptive.paclen", section: .linkLayer),
        Entry(setting: "adaptive.windowSize", section: .linkLayer),
        Entry(setting: "adaptive.maxRetries", section: .linkLayer),
        Entry(setting: AppSettingsStore.adaptiveTransmissionEnabledKey, section: .adaptiveTransmission),
        Entry(setting: "adaptive.learned", section: .adaptiveTransmission),
        Entry(setting: AppSettingsStore.axdpExtensionsEnabledKey, section: .axdpProtocol),
        Entry(setting: AppSettingsStore.axdpAutoNegotiateKey, section: .axdpProtocol),
        Entry(setting: AppSettingsStore.axdpCompressionEnabledKey, section: .axdpProtocol),
        Entry(setting: AppSettingsStore.axdpCompressionAlgorithmKey, section: .axdpProtocol),
        Entry(setting: AppSettingsStore.axdpShowDecodeDetailsKey, section: .axdpProtocol),
        Entry(setting: AppSettingsStore.allowedFileTransferCallsignsKey, section: .fileTransfer),
        Entry(setting: AppSettingsStore.deniedFileTransferCallsignsKey, section: .fileTransfer),
    ]

    // MARK: APRS

    private static let aprs: [Entry] = [
        Entry(setting: AppSettingsStore.aprsAutoReplyKey, section: .aprsMessaging),
        // Each APRS radio's own section.
        Entry(setting: "radio.aprsPath", section: .aprsRadios),
        Entry(setting: "radio.beacon.aprs.symbol", section: .aprsRadios),
        Entry(setting: "radio.beacon.aprs.comment", section: .aprsRadios),
        Entry(setting: "radio.beacon.aprs.useGPS", section: .aprsRadios),
        Entry(setting: "radio.beacon.aprs.latitude", section: .aprsRadios),
        Entry(setting: "radio.beacon.aprs.longitude", section: .aprsRadios),
        Entry(setting: "radio.beacon.aprs.ambiguityDigits", section: .aprsRadios),
        Entry(setting: "radio.beacon.aprs.compressed", section: .aprsRadios),
    ]
}
