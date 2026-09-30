//
//  RadioTimingTests.swift
//  AXTermTests
//
//  One Timing section on every radio, bound to the four RadioProfile
//  fields, and a change reaching whatever keys the transmitter: the sound
//  modem itself, a TNC whose link sends KISS timing, or (when asked) a
//  network or plain serial TNC through RadioManager.
//

import XCTest
@testable import AXTerm

@MainActor
final class RadioTimingTests: XCTestCase {

    private func radio(_ kind: RadioTransportKind, mobilinkd: Bool = false) -> RadioProfile {
        var radio = RadioProfile(id: RadioID(rawValue: "r-\(kind.rawValue)"), name: "R")
        radio.kind = kind
        radio.mobilinkdEnabled = mobilinkd
        radio.txDelayMs = 500
        radio.persistence = 128
        radio.slotTimeMs = 50
        radio.txTailMs = 30
        return radio
    }

    // MARK: - Who delivers the values

    func testEachTransportSaysHowItsTimingReachesTheAir() {
        XCTAssertEqual(radio(.modem).timingDelivery, .modem)
        XCTAssertEqual(radio(.ble).timingDelivery, .sentByLink)
        XCTAssertEqual(radio(.tcp).timingDelivery, .optional)
        #if os(macOS)
        XCTAssertEqual(radio(.serial, mobilinkd: true).timingDelivery, .sentByLink)
        #endif
        XCTAssertEqual(radio(.serial).timingDelivery, .optional)
    }

    func testANetworkTNCIsOnlySentTimingWhenAsked() {
        var tcp = radio(.tcp)
        XCTAssertFalse(tcp.managerSendsTiming)
        XCTAssertFalse(tcp.timingReachesTNC)
        tcp.sendsKISSTiming = true
        XCTAssertTrue(tcp.managerSendsTiming)
        XCTAssertTrue(tcp.timingReachesTNC)

        var ble = radio(.ble)
        ble.sendsKISSTiming = true
        XCTAssertFalse(ble.managerSendsTiming, "the Bluetooth link sends its own; never twice")
        XCTAssertTrue(ble.timingReachesTNC)
    }

    // MARK: - The values each link is built with

    func testTheModemIsBuiltWithTheRadiosTiming() throws {
        let config = try XCTUnwrap(radio(.modem).modemConfig)
        XCTAssertEqual(config.txDelayMs, 500)
        XCTAssertEqual(config.persistence, 128)
        XCTAssertEqual(config.slotTimeMs, 50)
        XCTAssertEqual(config.txTailMs, 30)
    }

    func testABluetoothTNCIsBuiltWithTheRadiosTiming() {
        XCTAssertEqual(radio(.ble).bleConfig.timing,
                       KISSTimingParameters(txDelayMs: 500, persistence: 128, slotTimeMs: 50, txTailMs: 30))
    }

    func testTheKISSFramesCarryTheValuesInTenMillisecondSteps() {
        let frames = radio(.tcp).kissTiming.frames(port: 1)
        XCTAssertEqual(frames[0], Data([0xC0, 0x11, 50, 0xC0]), "TXDELAY 500 ms on port 1")
        XCTAssertEqual(frames[1], Data([0xC0, 0x12, 128, 0xC0]), "persistence")
        XCTAssertEqual(frames[2], Data([0xC0, 0x13, 5, 0xC0]), "slot time 50 ms")
        XCTAssertEqual(frames[3], Data([0xC0, 0x14, 3, 0xC0]), "TX tail 30 ms")
    }

    // MARK: - The view model writes the profile

    func testTheTimingFieldsWriteTheProfileForEveryTransport() throws {
        for kind in RadioTransportKind.allCases {
            let settings = AppSettingsStore(defaults: TestDefaults.make("Timing-\(kind.rawValue)"))
            let id = try XCTUnwrap(settings.activeRadios.first?.id)
            settings.updateRadio(id) { $0.kind = kind }
            let client = PacketEngine(settings: settings)
            let model = ConnectionTransportViewModel(radioID: id, settings: settings, packetEngine: client)
            model.txDelayMs = 500
            model.persistence = 200
            model.slotTimeMs = 60
            model.txTailMs = 40
            model.sendsKISSTiming = true
            let stored = try XCTUnwrap(settings.radio(id))
            XCTAssertEqual(stored.txDelayMs, 500, "\(kind)")
            XCTAssertEqual(stored.persistence, 200, "\(kind)")
            XCTAssertEqual(stored.slotTimeMs, 60, "\(kind)")
            XCTAssertEqual(stored.txTailMs, 40, "\(kind)")
            XCTAssertTrue(stored.sendsKISSTiming, "\(kind)")
        }
    }

    // MARK: - RadioManager sends it to a network TNC

    private var links: [String: KISSLinkLoopback] = [:]

    private func makeManager() -> RadioManager {
        links = [:]
        return RadioManager(linkFactory: { [weak self] profile in
            let link = KISSLinkLoopback()
            link.loopbackEnabled = false
            self?.links[profile.linkKey] = link
            return link
        })
    }

    func testANetworkTNCIsLeftAloneByDefault() {
        let manager = makeManager()
        manager.reconcile([radio(.tcp)], open: true)
        XCTAssertEqual(links.values.first?.sentData, [], "nothing sent unless asked")
    }

    func testANetworkTNCIsSentTheTimingOnConnectOnItsOwnPort() throws {
        let manager = makeManager()
        var tcp = radio(.tcp)
        tcp.kissPort = 1
        tcp.sendsKISSTiming = true
        manager.reconcile([tcp], open: true)
        let link = try XCTUnwrap(links.values.first)
        XCTAssertEqual(link.sentData, [tcp.kissTiming.frames(port: 1).reduce(Data(), +)])
    }

    func testAChangedValueIsSentWhileConnectedAndAnUnchangedOneIsNot() throws {
        let manager = makeManager()
        var tcp = radio(.tcp)
        tcp.sendsKISSTiming = true
        manager.reconcile([tcp], open: true)
        let link = try XCTUnwrap(links.values.first)
        XCTAssertEqual(link.sentData.count, 1)

        manager.reconcile([tcp], open: true)
        XCTAssertEqual(link.sentData.count, 1, "a settings write that leaves timing alone sends nothing")

        tcp.txDelayMs = 400
        manager.reconcile([tcp], open: true)
        XCTAssertEqual(link.sentData.count, 2)
        XCTAssertEqual(link.sentData.last, tcp.kissTiming.frames(port: 0).reduce(Data(), +))
    }

    /// While a radio's settings page is open the engine does not reconcile,
    /// but a timing change still reaches the TNC; a transport change waits.
    func testATimingChangeReachesTheLinkWhileSettingsAreOpen() throws {
        let manager = makeManager()
        var tcp = radio(.tcp)
        tcp.sendsKISSTiming = true
        manager.reconcile([tcp], open: true)
        let link = try XCTUnwrap(links.values.first)
        XCTAssertEqual(link.sentData.count, 1)

        tcp.txDelayMs = 450
        manager.applyInPlace([tcp])
        XCTAssertEqual(link.sentData.count, 2)
        XCTAssertEqual(link.sentData.last, tcp.kissTiming.frames(port: 0).reduce(Data(), +))

        var moved = tcp
        moved.host = "10.0.0.9"
        moved.txDelayMs = 600
        manager.applyInPlace([moved])
        XCTAssertEqual(link.sentData.count, 2, "a radio whose transport changed waits for the reconcile")
        XCTAssertEqual(manager.sessions.count, 1, "and nothing was opened")
    }

    func testAReconnectSendsItAgain() throws {
        let manager = makeManager()
        var tcp = radio(.tcp)
        tcp.sendsKISSTiming = true
        manager.reconcile([tcp], open: true)
        let link = try XCTUnwrap(links.values.first)
        link.close()
        link.open()
        XCTAssertEqual(link.sentData.count, 2, "a TNC that may have restarted is told again")
    }

    // MARK: - What the section says

    func testTheFooterSaysWhereTheValuesGo() {
        XCTAssertTrue(RadioTimingSection.footer(delivery: .modem, sendsTiming: false).contains("sound modem"))
        XCTAssertTrue(RadioTimingSection.footer(delivery: .sentByLink, sendsTiming: false).contains("every time"))
        XCTAssertTrue(RadioTimingSection.footer(delivery: .optional, sendsTiming: false).contains("not sent"))
        XCTAssertTrue(RadioTimingSection.footer(delivery: .optional, sendsTiming: true).contains("direwolf.conf"))
    }

    func testTheTooltipsExplainEachValue() {
        XCTAssertTrue(RadioTimingSection.txDelayHelp.contains("milliseconds"))
        XCTAssertTrue(RadioTimingSection.txDelayHelp.contains("500 ms"), "the IC-V8's figure")
        XCTAssertTrue(RadioTimingSection.persistenceHelp.contains("256"))
        XCTAssertTrue(RadioTimingSection.slotTimeHelp.contains("100 ms"))
        XCTAssertTrue(RadioTimingSection.txTailHelp.contains("PTT"))
    }
}
