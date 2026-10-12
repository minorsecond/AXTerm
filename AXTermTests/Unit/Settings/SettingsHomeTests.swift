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
            // Digipeater (single radio) and the pointer to the radios (several).
            // Fill-in, wide-area and the dupe window are APRS rules and live
            // on the APRS page only (operator, 2026-10-10).
            ("radio.digi.enabled", .packetRadios),
            ("radio.digi.aliases", .packetRadios),
            // Ping
            (AppSettingsStore.pingEnabledKey, .ping),
            ("radio.pings", .ping),
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
            // Packet Node redesign (finding 46): the radios that carry the
            // node are chosen in the node's own card.
            ("radio.netRomAlias", .netRomNode),
            ("radio.announcesNode", .netRomNode),
            (AppSettingsStore.netRomBroadcastMinutesKey, .netRomNode),
            (AppSettingsStore.netRomForwardingKey, .netRomNode),
            // AXDP
            (AppSettingsStore.axdpExtensionsEnabledKey, .axdpProtocol),
            (AppSettingsStore.axdpAutoNegotiateKey, .axdpProtocol),
            (AppSettingsStore.axdpCompressionEnabledKey, .axdpProtocol),
            (AppSettingsStore.axdpCompressionAlgorithmKey, .axdpProtocol),
            (AppSettingsStore.axdpShowDecodeDetailsKey, .axdpProtocol),
        ]
        // For a packet radio: the digipeater has a home on each channel's
        // page now (testTheDigipeaterHasAHomeOnEachChannel).
        for (setting, expected) in moved {
            XCTAssertEqual(SettingsHome.section(of: setting, channel: .packet), expected, setting)
        }
        let homes = Set(moved.compactMap { SettingsHome.section(of: $0.0, channel: .packet)?.tab })
        XCTAssertEqual(homes, [.packetNode], "the Transmission page's controls went to Packet Node")
        // File transfers have a page of their own since the redesign.
        for setting in [AppSettingsStore.allowedFileTransferCallsignsKey,
                        AppSettingsStore.deniedFileTransferCallsignsKey] {
            XCTAssertEqual(SettingsHome.section(of: setting), .fileTransfer)
        }
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
        // A packet radio's own sections hold its ID beacon; which radios
        // carry the node, ping and the mailbox is chosen in each service's
        // card (finding 46).
        for setting in ["radio.beacon.text", "radio.beacon.path"] {
            XCTAssertEqual(SettingsHome.section(of: setting), .packetRadios, setting)
        }
        for setting in ["radio.announcesNode", "radio.netRomAlias", "radio.pings", "radio.answersMailbox"] {
            XCTAssertEqual(SettingsHome.section(of: setting)?.tab, .packetNode, setting)
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
                       Set(["radio.beacon.enabled", "radio.beacon.intervalMinutes"]).union(Self.digiSettings))
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

    private static let digiSettings: Set<String> = ["radio.digi.enabled", "radio.digi.aliases"]
    private static let aprsDigiSettings: Set<String> = [
        "radio.digi.fillIn", "radio.digi.wideAreaMaxHops", "radio.digi.dupeSeconds",
    ]

    /// A radio's digipeater is set where the radio works. Its switch and
    /// aliases are on each channel's page. It was on Packet Node only, so an
    /// APRS radio had nowhere to switch it on (operator, 2026-10-09).
    func testTheDigipeaterHasAHomeOnEachChannel() {
        for setting in Self.digiSettings {
            XCTAssertEqual(SettingsHome.section(of: setting, channel: .aprs), .aprsRadios, setting)
            XCTAssertEqual(SettingsHome.section(of: setting, channel: .packet), .packetRadios, setting)
            XCTAssertNil(SettingsHome.section(of: setting), "\(setting) has a home per channel")
        }
    }

    /// Fill-in, wide-area and the dupe window are APRS rules: their one home
    /// is the APRS page. On Packet Node they showed as though a packet node
    /// answered WIDE1-1 (operator, 2026-10-10).
    func testTheAPRSDigipeaterRulesLiveOnTheAPRSPageOnly() {
        for setting in Self.aprsDigiSettings {
            XCTAssertEqual(SettingsHome.section(of: setting), .aprsRadios, setting)
            XCTAssertNotEqual(SettingsHome.section(of: setting, channel: .packet), .packetRadios, setting)
        }
    }

    // MARK: - Packet Node redesign (park rehearsal 2026-10-08, finding 46)

    /// One card per service, with the radios that carry it chosen in the
    /// card: ping in Ping, the mailbox in its own card.
    func testEachServicesRadiosAreChosenInItsCard() {
        XCTAssertEqual(SettingsHome.section(of: "radio.pings"), .ping)
        XCTAssertEqual(SettingsHome.section(of: "radio.answersMailbox"), .packetMailbox)
        XCTAssertEqual(SettingsSection.packetMailbox.tab, .packetNode)
    }

    func testFileTransfersHaveTheirOwnPage() {
        XCTAssertEqual(SettingsSection.fileTransfer.tab, .fileTransfers)
        XCTAssertEqual(SettingsTab.fileTransfers.settingsTitle, "File Transfers")
        let order = SettingsTab.sidebarOrder
        XCTAssertEqual(order.firstIndex(of: .fileTransfers), order.firstIndex(of: .packetNode).map { $0 + 1 })
    }

    /// Owner sign-in, paired devices, control commands and radios control
    /// the whole station, not the mailbox, and the node offers them too
    /// (operator, 2026-10-12): their own page, after the services.
    func testRemoteControlHasItsOwnPage() {
        XCTAssertEqual(SettingsTab.remoteControl.settingsTitle, "Remote Control")
        let order = SettingsTab.sidebarOrder
        let after = order.firstIndex(of: .bbs) ?? order.firstIndex(of: .fileTransfers)
        XCTAssertEqual(order.firstIndex(of: .remoteControl), after.map { $0 + 1 })
    }
}

