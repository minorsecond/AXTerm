//
//  SettingsHomeTests.swift
//  AXTermTests
//
//  Every setting has one home, and the Transmission page's controls all
//  found a new one when the page went away. A radio's page holds its
//  hardware; what it does on the air is on the service page for its channel.
//

import XCTest
@testable import AXTerm

@MainActor
final class SettingsHomeTests: XCTestCase {

    func testEverySettingHasExactlyOneHome() {
        var seen: [String: SettingsSection] = [:]
        for entry in SettingsHome.entries {
            if let first = seen[entry.setting] {
                XCTFail("\(entry.setting) is on \(first) and \(entry.section)")
            }
            seen[entry.setting] = entry.section
        }
    }

    func testEveryHomeIsAPageInTheSidebar() {
        for section in SettingsSection.allCases {
            XCTAssertTrue(SettingsTab.sidebarOrder.contains(section.tab),
                          "\(section) is on \(section.tab), which the sidebar does not list")
        }
    }

    func testEverySectionHoldsSomething() {
        for section in SettingsSection.allCases {
            XCTAssertFalse(SettingsHome.entries.filter { $0.section == section }.isEmpty,
                           "\(section) is a landing with nothing registered on it")
        }
    }

    /// The controls the Transmission page had, and where each one lives now.
    /// All of them are on Packet Node: a station-wide control in its own
    /// section, a per-radio one in that radio's sections.
    func testEveryTransmissionControlHasANewHome() {
        let moved: [(String, SettingsSection)] = [
            // Adaptive Transmission
            (AppSettingsStore.adaptiveTransmissionEnabledKey, .adaptiveTransmission),
            ("adaptive.learned", .adaptiveTransmission),
            // Its PACLEN / K / N2 grid repeated the Link Layer's; one home now.
            ("adaptive.paclen", .linkLayer),
            ("adaptive.windowSize", .linkLayer),
            ("adaptive.maxRetries", .linkLayer),
            // Link Layer
            (AppSettingsStore.ax25T1TimeoutSecondsKey, .linkLayer),
            (AppSettingsStore.ax25NegotiateV22Key, .linkLayer),
            // Digipeater (single radio) and the pointer to the radios (several)
            ("radio.digi.enabled", .packetRadios),
            ("radio.digi.fillIn", .packetRadios),
            ("radio.digi.wideAreaMaxHops", .packetRadios),
            ("radio.digi.aliases", .packetRadios),
            ("radio.digi.dupeSeconds", .packetRadios),
            // Ping
            (AppSettingsStore.pingEnabledKey, .ping),
            ("radio.pings", .packetRadios),
            (AppSettingsStore.pingWindowStartKey, .ping),
            (AppSettingsStore.pingWindowEndKey, .ping),
            (AppSettingsStore.pingMaxPerHourKey, .ping),
            (AppSettingsStore.pingSpacingKey, .ping),
            (AppSettingsStore.pingBoxCooldownKey, .ping),
            (AppSettingsStore.pingCooldownKey, .ping),
            (AppSettingsStore.pingProbeCalledKey, .ping),
            // NET/ROM Node
            (AppSettingsStore.netRomAcceptInboundKey, .netRomNode),
            (AppSettingsStore.autoRouteMaxChainLengthKey, .netRomNode),
            (AppSettingsStore.netRomNodeAliasKey, .netRomNode),
            (AppSettingsStore.netRomAdvertiseKey, .netRomNode),
            (AppSettingsStore.netRomNodeIdentityKey, .netRomNode),
            ("radio.netRomAlias", .packetRadios),
            ("radio.announcesNode", .packetRadios),
            (AppSettingsStore.netRomBroadcastMinutesKey, .netRomNode),
            (AppSettingsStore.netRomForwardingKey, .netRomNode),
            // AXDP
            (AppSettingsStore.axdpExtensionsEnabledKey, .axdpProtocol),
            (AppSettingsStore.axdpAutoNegotiateKey, .axdpProtocol),
            (AppSettingsStore.axdpCompressionEnabledKey, .axdpProtocol),
            (AppSettingsStore.axdpCompressionAlgorithmKey, .axdpProtocol),
            (AppSettingsStore.axdpShowDecodeDetailsKey, .axdpProtocol),
            // File transfers
            (AppSettingsStore.allowedFileTransferCallsignsKey, .fileTransfer),
            (AppSettingsStore.deniedFileTransferCallsignsKey, .fileTransfer),
        ]
        for (setting, expected) in moved {
            XCTAssertEqual(SettingsHome.section(of: setting), expected, setting)
        }
        let homes = Set(moved.compactMap { SettingsHome.section(of: $0.0)?.tab })
        XCTAssertEqual(homes, [.packetNode], "the Transmission page's controls went to Packet Node")
        // Its beacon pointer: the beacon is a packet radio's ID beacon there.
        XCTAssertEqual(SettingsHome.section(of: "radio.beacon.enabled", channel: .packet), .packetRadios)
    }

    /// A radio's page holds how it is reached, its identity, its channel and
    /// its timing. What it does on the air is on its channel's service page.
    func testHardwareOnTheRadioPageRoleOnTheServicePage() {
        for setting in ["radio.kind", "radio.host", "radio.tnc4", "radio.modem",
                        "radio.aprsEnabled", "radio.callsign", "radio.txDelayMs",
                        "radio.persistence", "radio.slotTimeMs", "radio.txTailMs"] {
            XCTAssertEqual(SettingsHome.section(of: setting)?.tab, .radios, setting)
        }
        XCTAssertEqual(SettingsHome.section(of: "radio.aprsEnabled"), .radioChannel)
        XCTAssertEqual(SettingsHome.section(of: "radio.beacon.kind"), .radioChannel,
                       "the channel sets the beacon's kind")

        for setting in ["radio.aprsPath", "radio.beacon.aprs.symbol", "radio.beacon.aprs.comment",
                        "radio.beacon.aprs.useGPS", "radio.beacon.aprs.latitude",
                        "radio.beacon.aprs.ambiguityDigits", "radio.beacon.aprs.compressed"] {
            XCTAssertEqual(SettingsHome.section(of: setting), .aprsRadios, setting)
        }
        for setting in ["radio.announcesNode", "radio.netRomAlias", "radio.pings",
                        "radio.answersMailbox", "radio.digi.enabled", "radio.digi.aliases",
                        "radio.beacon.text", "radio.beacon.path"] {
            XCTAssertEqual(SettingsHome.section(of: setting), .packetRadios, setting)
        }

        let onRadioPage = SettingsHome.settings(on: .radios)
        for setting in onRadioPage where setting.hasPrefix("radio.beacon") {
            XCTAssertEqual(setting, "radio.beacon.kind", "\(setting) is a role, not hardware")
        }
        XCTAssertFalse(onRadioPage.contains { $0.hasPrefix("radio.digi") })
    }

    /// The beacon's switch and interval are one stored value per radio, sent
    /// as a position beacon on APRS and an ID beacon on packet. They have a
    /// home on each service page and are kept out of the one-home list.
    func testTheBeaconSwitchAndIntervalHaveAHomePerChannel() {
        XCTAssertEqual(Set(SettingsHome.byChannel.map(\.setting)),
                       ["radio.beacon.enabled", "radio.beacon.intervalMinutes"])
        for entry in SettingsHome.byChannel {
            XCTAssertNil(SettingsHome.section(of: entry.setting),
                         "\(entry.setting) has no single home, so it is not in entries")
            XCTAssertEqual(SettingsHome.section(of: entry.setting, channel: .aprs), .aprsRadios)
            XCTAssertEqual(SettingsHome.section(of: entry.setting, channel: .packet), .packetRadios)
            XCTAssertEqual(entry.aprs.tab, .aprs)
            XCTAssertEqual(entry.packet.tab, .packetNode)
        }
        // A setting with one home answers the same whatever the channel.
        XCTAssertEqual(SettingsHome.section(of: "radio.aprsPath", channel: .packet), .aprsRadios)
    }

    /// The APRS page holds messaging for the station and each APRS radio's
    /// path and position beacon.
    func testTheAPRSPageHoldsMessagingAndEachAPRSRadiosRole() {
        let onAPRS = SettingsHome.settings(on: .aprs)
        XCTAssertEqual(onAPRS.filter { !$0.hasPrefix("radio.") }, [AppSettingsStore.aprsAutoReplyKey])
        XCTAssertEqual(SettingsHome.section(of: AppSettingsStore.aprsAutoReplyKey), .aprsMessaging)
        XCTAssertTrue(onAPRS.contains("radio.aprsPath"))
        XCTAssertTrue(onAPRS.filter { $0.hasPrefix("radio.") }
            .allSatisfy { SettingsHome.section(of: $0) == .aprsRadios })
    }

    /// One grid square, under General. Winlink shows it and does not edit it.
    func testTheGridSquareLivesUnderGeneral() {
        XCTAssertEqual(SettingsHome.section(of: WinlinkSettings.gridSquareKey), .stationPosition)
        XCTAssertEqual(SettingsSection.stationPosition.tab, .general)
        XCTAssertTrue(SettingsHome.settings(on: .winlink).isEmpty)
    }

    func testThereIsNoTransmissionPage() {
        XCTAssertFalse(SettingsTab.sidebarOrder.map(\.settingsTitle).contains("Transmission"))
        XCTAssertTrue(SettingsTab.sidebarOrder.contains(.packetNode))
        XCTAssertEqual(SettingsTab.packetNode.settingsTitle, "Packet Node")
    }
}
