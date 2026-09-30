//
//  SettingsHomeTests.swift
//  AXTermTests
//
//  Every setting has one home, and the Transmission page's controls all
//  found a new one when the page went away.
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
    /// A per-radio control went to the radio's page, a station-wide one to
    /// Packet Node.
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
            ("radio.digi.enabled", .radioDigipeater),
            ("radio.digi.fillIn", .radioDigipeater),
            ("radio.digi.wideAreaMaxHops", .radioDigipeater),
            ("radio.digi.aliases", .radioDigipeater),
            ("radio.digi.dupeSeconds", .radioDigipeater),
            // Beacon pointer
            ("radio.beacon.enabled", .radioBeacon),
            // Ping
            (AppSettingsStore.pingEnabledKey, .ping),
            ("radio.pings", .radioPacketServices),
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
            ("radio.netRomAlias", .radioPacketServices),
            ("radio.announcesNode", .radioPacketServices),
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
        XCTAssertEqual(homes, [.packetNode, .radios],
                       "the Transmission page's controls went to Packet Node and the radio page")
    }

    /// The other per-radio controls that were spread over the APRS page and
    /// the old radio pages.
    func testPerRadioSettingsLiveOnTheRadioPage() {
        for setting in ["radio.aprsEnabled", "radio.aprsPath", "radio.callsign",
                        "radio.beacon.aprs.symbol", "radio.beacon.aprs.useGPS",
                        "radio.answersMailbox", "radio.txDelayMs", "radio.persistence",
                        "radio.slotTimeMs", "radio.txTailMs"] {
            XCTAssertEqual(SettingsHome.section(of: setting)?.tab, .radios, setting)
        }
        XCTAssertEqual(SettingsHome.section(of: "radio.aprsEnabled"), .radioChannel)
    }

    /// The APRS page keeps only what is station-wide.
    func testTheAPRSPageHoldsOnlyStationWideSettings() {
        XCTAssertEqual(SettingsHome.settings(on: .aprs), [AppSettingsStore.aprsAutoReplyKey])
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
