//
//  SettingsHome.swift
//  AXTerm
//
//  Where each setting lives. One page and one section per setting, and the
//  page does not change when a second radio is added. The deep links read
//  this table, so "open the setting" and "where the setting is" cannot drift
//  apart, and a test checks that nothing is registered twice.
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
    case radioAPRSPath
    case radioBeacon
    case radioPacketServices
    case radioDigipeater
    case radioTiming

    // Packet Node
    case netRomNode
    case ping
    case linkLayer
    case adaptiveTransmission
    case axdpProtocol
    case fileTransfer

    // APRS
    case aprsMessaging

    /// The page this section is on.
    var tab: SettingsTab {
        switch self {
        case .stationIdentity, .stationPosition, .display, .online, .system:
            return .general
        case .radioConnection, .radioReceiveAudio, .radioIdentity, .radioChannel, .radioAPRSPath,
             .radioBeacon, .radioPacketServices, .radioDigipeater, .radioTiming:
            return .radios
        case .netRomNode, .ping, .linkLayer, .adaptiveTransmission, .axdpProtocol, .fileTransfer:
            return .packetNode
        case .aprsMessaging:
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
        Entry(setting: "radio.aprsPath", section: .radioAPRSPath),
        // One beacon per radio. Its channel decides whether the section is
        // the APRS position beacon or the ID beacon; it is the same section.
        Entry(setting: "radio.beacon.enabled", section: .radioBeacon),
        Entry(setting: "radio.beacon.kind", section: .radioBeacon),
        Entry(setting: "radio.beacon.text", section: .radioBeacon),
        Entry(setting: "radio.beacon.path", section: .radioBeacon),
        Entry(setting: "radio.beacon.intervalMinutes", section: .radioBeacon),
        Entry(setting: "radio.beacon.aprs.symbol", section: .radioBeacon),
        Entry(setting: "radio.beacon.aprs.comment", section: .radioBeacon),
        Entry(setting: "radio.beacon.aprs.useGPS", section: .radioBeacon),
        Entry(setting: "radio.beacon.aprs.latitude", section: .radioBeacon),
        Entry(setting: "radio.beacon.aprs.longitude", section: .radioBeacon),
        Entry(setting: "radio.beacon.aprs.ambiguityDigits", section: .radioBeacon),
        Entry(setting: "radio.beacon.aprs.compressed", section: .radioBeacon),
        Entry(setting: "radio.announcesNode", section: .radioPacketServices),
        Entry(setting: "radio.netRomAlias", section: .radioPacketServices),
        Entry(setting: "radio.pings", section: .radioPacketServices),
        Entry(setting: "radio.answersMailbox", section: .radioPacketServices),
        Entry(setting: "radio.digi.enabled", section: .radioDigipeater),
        Entry(setting: "radio.digi.fillIn", section: .radioDigipeater),
        Entry(setting: "radio.digi.wideAreaMaxHops", section: .radioDigipeater),
        Entry(setting: "radio.digi.aliases", section: .radioDigipeater),
        Entry(setting: "radio.digi.dupeSeconds", section: .radioDigipeater),
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
    ]
}
