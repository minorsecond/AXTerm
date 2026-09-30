import Combine
import SwiftUI
import XCTest
@testable import AXTerm

/// Every frame carries the address of the radio it leaves on.
///
/// The station callsign is the base call (K0EPI) and no radio here operates
/// under it: the primary radio is K0EPI-5 and the second is K0EPI-7, both on
/// one Direwolf at KISS ports 0 and 1. A frame that went out as the bare base
/// would be a station nobody configured; a frame from one radio carrying the
/// other's SSID would send the answer to the wrong channel.
@MainActor
final class PerRadioSourceAddressTests: XCTestCase {

    private var link: KISSLinkLoopback?
    private var primary = RadioID.primary
    private var uhf = RadioID.primary

    private func makeStation() -> (PacketEngine, SessionCoordinator, AppSettingsStore) {
        let settings = AppSettingsStore(defaults: TestDefaults.make("PerRadioSourceAddress"))
        settings.myCallsign = "K0EPI"
        primary = settings.radios[0].id
        settings.updateRadio(primary) {
            $0.host = "127.0.0.1"; $0.port = 8001; $0.kissPort = 0; $0.callsign = "K0EPI-5"
        }
        let second = settings.addRadio()
        uhf = second.id
        settings.updateRadio(uhf) {
            $0.name = "UHF"; $0.host = "127.0.0.1"; $0.port = 8001; $0.kissPort = 1; $0.callsign = "K0EPI-7"
        }

        let engine = PacketEngine(settings: settings, linkFactory: { [weak self] _ in
            if let existing = self?.link { return existing }
            let fresh = KISSLinkLoopback()
            fresh.loopbackEnabled = false
            self?.link = fresh
            return fresh
        })
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = settings.primaryCallsign
        coordinator.appSettings = settings
        coordinator.subscribeToPackets(from: engine)
        return (engine, coordinator, settings)
    }

    /// Connects, and lets the coordinator learn the radios' addresses, which
    /// it does on the main run loop.
    private func connect(_ engine: PacketEngine) async {
        engine.connectUsingSettings()
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    private var replies: [(port: UInt8, frame: AX25.FrameDecodeResult)] {
        (link?.sentData ?? []).compactMap { kiss in
            var parser = KISSFrameParser()
            guard let frame = parser.feedFrames(kiss).first,
                  case .ax25(let ax25) = frame.output,
                  let decoded = AX25.decodeFrame(ax25: ax25) else { return nil }
            return (frame.port, decoded)
        }
    }

    private func waitForReplies(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 where replies.count < count {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        if replies.count < count {
            XCTFail("expected \(count) frame(s), got \(replies.count)", file: file, line: line)
        }
    }

    private let peer = AX25Address(call: "PEER", ssid: 1)

    // MARK: - Addresses answered

    func testTheStationAnswersEachRadiosAddressAndNotTheBareBase() async {
        let (engine, coordinator, _) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)

        let answered = Set(coordinator.sessionManager.answeredAddresses.map(\.display))
        XCTAssertEqual(coordinator.localCallsign, "K0EPI-5", "the fallback is the primary radio's address")
        XCTAssertTrue(answered.isSuperset(of: ["K0EPI-5", "K0EPI-7"]), "\(answered)")
        XCTAssertFalse(answered.contains("K0EPI"), "no radio operates as the bare base: \(answered)")
        XCTAssertFalse(coordinator.sessionManager.answers(AX25Address(call: "K0EPI")))
    }

    func testChangingThePrimarysSSIDMovesTheFallback() async {
        let (engine, coordinator, settings) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)

        settings.updateRadio(primary) { $0.callsign = "K0EPI-9" }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(coordinator.localCallsign, "K0EPI-9")
        XCTAssertEqual(coordinator.sessionManager.localAddress(for: primary).display, "K0EPI-9")
        XCTAssertEqual(coordinator.sessionManager.localAddress(for: uhf).display, "K0EPI-7")
    }

    // MARK: - Beacons and APRS

    func testABeaconCarriesItsRadiosCallsign() async {
        let (engine, coordinator, settings) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)
        settings.updateRadio(uhf) {
            $0.beacon = BeaconConfig(enabled: true, kind: .text, text: "AXTerm test", path: "",
                                     intervalMinutes: 30)
        }

        coordinator.sendBeacon(for: uhf, settings: settings)
        await waitForReplies(1)

        XCTAssertEqual(replies.first?.port, 1)
        XCTAssertEqual(replies.first?.frame.from?.display, "K0EPI-7")
    }

    func testAnAPRSMessageLeavesUnderItsRadiosCallsign() async {
        let (engine, coordinator, _) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)

        XCTAssertEqual(coordinator.aprsCallsign(forRadio: uhf.rawValue, addressee: "PEER-1"), "K0EPI-7")
        _ = coordinator.sendAPRS(APRSOutbound(info: ":PEER-1   :hello{1", addressee: "PEER-1",
                                              path: [], radioID: uhf.rawValue))
        await waitForReplies(1)

        XCTAssertEqual(replies.first?.port, 1)
        XCTAssertEqual(replies.first?.frame.from?.display, "K0EPI-7")
    }

    func testAPRSAddressedToUsMeansARadiosAddress() {
        let (engine, coordinator, _) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }

        XCTAssertEqual(Set(engine.aprsOurCallsigns()), ["K0EPI-5", "K0EPI-7"],
                       "a message to the bare base is for another of the operator's stations")
    }

    // MARK: - Connected mode

    func testASABMToTheSecondRadioIsAnsweredFromIt() async {
        let (engine, coordinator, _) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)

        let sabm = AX25FrameBuilder.buildSABM(from: peer, to: AX25Address(call: "K0EPI", ssid: 7),
                                              via: DigiPath(), extended: false).encodeAX25()
        link!.injectReceived(KISS.encodeFrame(payload: sabm, port: 1))
        await waitForReplies(1)

        XCTAssertEqual(replies.first?.port, 1)
        XCTAssertEqual(replies.first?.frame.from?.display, "K0EPI-7")
        XCTAssertEqual(replies.first?.frame.to?.display, "PEER-1")
    }

    func testASABMToTheBareBaseIsNotAnswered() async {
        let (engine, coordinator, _) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)

        let sabm = AX25FrameBuilder.buildSABM(from: peer, to: AX25Address(call: "K0EPI"),
                                              via: DigiPath(), extended: false).encodeAX25()
        link!.injectReceived(KISS.encodeFrame(payload: sabm, port: 0))
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(replies.isEmpty, "K0EPI is not an address this station operates as")
    }

    func testADISCWithNoSessionIsRefusedFromTheRadioItWasFor() async {
        let (engine, coordinator, _) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)

        let disc = AX25FrameBuilder.buildDISC(from: peer, to: AX25Address(call: "K0EPI", ssid: 7)).encodeAX25()
        link!.injectReceived(KISS.encodeFrame(payload: disc, port: 1))
        await waitForReplies(1)

        XCTAssertEqual(replies.first?.port, 1)
        XCTAssertEqual(replies.first?.frame.from?.display, "K0EPI-7", "the DM comes from the radio called")
    }

    func testAnXIDCommandIsAnsweredFromTheRadiosAddress() async {
        let (engine, coordinator, _) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)

        let responses = coordinator.sessionManager.handleInboundXID(
            from: peer, path: DigiPath(), radio: uhf, info: Data(), isCommand: true, pf: true)

        XCTAssertEqual(responses.first?.source.display, "K0EPI-7")
        XCTAssertEqual(responses.first?.radio, uhf)
    }

    func testASABMEIsRefusedFromTheCalledAddress() async {
        let (engine, coordinator, _) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)

        let dm = coordinator.sessionManager.handleInboundSABM(
            from: peer, to: AX25Address(call: "K0EPI", ssid: 7), path: DigiPath(),
            radio: uhf, extended: true)

        XCTAssertEqual(dm?.source.display, "K0EPI-7")
        XCTAssertEqual(dm?.radio, uhf)
    }

    // MARK: - AXDP

    func testAnAXDPPongAnswersFromTheRadioThePingArrivedOn() async {
        let (engine, coordinator, _) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)

        let ping = AXDP.Message(type: .ping, sessionId: 0, messageId: 1,
                                capabilities: AXDPCapability.defaultLocal())
        coordinator.handleCapabilityMessage(ping, from: peer, path: DigiPath(), radio: uhf)
        await waitForReplies(1)

        XCTAssertEqual(replies.first?.port, 1)
        XCTAssertEqual(replies.first?.frame.from?.display, "K0EPI-7")
    }

    func testAnAXDPFrameWithNoRadioLeavesOnThePrimary() async {
        let (engine, coordinator, _) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)

        let origin = coordinator.uiOrigin(to: peer, radio: nil)

        XCTAssertEqual(origin.radio, primary)
        XCTAssertEqual(origin.source.display, "K0EPI-5")
    }

    // MARK: - NET/ROM

    func testOneNodeOnEveryRadioIsThePrimarysAddress() async {
        let (engine, coordinator, settings) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)
        settings.netRomNodeIdentity = .unified

        XCTAssertEqual(coordinator.netRomDriver.localNode.display, "K0EPI-5")
        XCTAssertEqual(Set(coordinator.announcements().map(\.node.display)), ["K0EPI-5"])
    }

    func testANodePerRadioUsesEachRadiosAddress() async {
        let (engine, coordinator, settings) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)
        settings.netRomNodeIdentity = .perRadio

        XCTAssertEqual(Set(coordinator.announcements().map(\.node.display)), ["K0EPI-5", "K0EPI-7"])
    }

    // MARK: - Receive side

    func testAnotherDeviceOnTheBareBaseIsNotACollision() async {
        let (engine, coordinator, _) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)

        let handheld = AX25FrameBuilder.buildUI(from: AX25Address(call: "K0EPI"), to: AX25Address(call: "BEACON"),
                                                via: DigiPath(), pid: 0xF0, payload: Data("hi".utf8),
                                                displayInfo: nil)
        link!.injectReceived(KISS.encodeFrame(payload: handheld.encodeAX25(), port: 0))
        XCTAssertNil(engine.identityCollision, "the operator's handheld on K0EPI is not us")

        let impostor = AX25FrameBuilder.buildUI(from: AX25Address(call: "K0EPI", ssid: 7),
                                                to: AX25Address(call: "BEACON"), via: DigiPath(),
                                                pid: 0xF0, payload: Data("never sent".utf8),
                                                displayInfo: nil)
        link!.injectReceived(KISS.encodeFrame(payload: impostor.encodeAX25(), port: 0))
        XCTAssertEqual(engine.identityCollision?.callsign, "K0EPI-7")
    }

    func testTheDigipeaterAnswersToItsRadiosCallsign() async {
        let (engine, coordinator, settings) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        settings.updateRadio(uhf) {
            $0.digi = DigiConfig(enabled: true, fillIn: false, wideAreaMaxHops: 0, aliases: [])
        }
        await connect(engine)

        let viaBase = AX25FrameBuilder.buildUI(from: peer, to: AX25Address(call: "APRS"),
                                               via: DigiPath.from(["K0EPI"]), pid: 0xF0,
                                               payload: Data("base".utf8), displayInfo: nil)
        link!.injectReceived(KISS.encodeFrame(payload: viaBase.encodeAX25(), port: 1))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(replies.isEmpty, "the bare base is not this radio's call")

        let viaUHF = AX25FrameBuilder.buildUI(from: peer, to: AX25Address(call: "APRS"),
                                              via: DigiPath.from(["K0EPI-7"]), pid: 0xF0,
                                              payload: Data("uhf".utf8), displayInfo: nil)
        link!.injectReceived(KISS.encodeFrame(payload: viaUHF.encodeAX25(), port: 1))
        await waitForReplies(1)

        XCTAssertEqual(replies.first?.port, 1)
        XCTAssertEqual(replies.first?.frame.via.first?.display, "K0EPI-7")
        XCTAssertEqual(replies.first?.frame.via.first?.repeated, true)
    }

    func testSessionChatIsAddressedToTheSessionsRadio() {
        let (engine, coordinator, _) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }

        engine.appendSessionChatLine(from: "PEER-1", text: "hello", radioID: uhf)

        XCTAssertEqual(engine.consoleLines.last?.to, "K0EPI-7")
    }

    // MARK: - Terminal

    func testATerminalDatagramCarriesTheSelectedRadiosCallsign() async {
        let (engine, coordinator, settings) = makeStation()
        defer { withExtendedLifetime((engine, coordinator)) {} }
        await connect(engine)
        let terminal = ObservableTerminalTxViewModel(client: engine, settings: settings,
                                                     sourceCall: settings.primaryCallsign,
                                                     sessionManager: coordinator.sessionManager)
        terminal.radioSelection = uhf
        terminal.destinationCall.wrappedValue = "PEER-1"
        terminal.composeText.wrappedValue = "hello"

        terminal.enqueueCurrentMessage()

        XCTAssertEqual(terminal.queueEntries.last?.frame.source.display, "K0EPI-7")
        XCTAssertEqual(terminal.queueEntries.last?.frame.radio, uhf)
    }
}

/// The station an older build left behind: one radio, and the SSID on the
/// station callsign. After the migration it is on the air exactly as before.
@MainActor
final class MigratedSingleRadioOnAirTests: XCTestCase {

    private var link: KISSLinkLoopback?

    func testAMigratedStationAnswersUnderItsOldAddress() async {
        let defaults = TestDefaults.make("MigratedSingleRadio")
        defaults.set("K0EPI-5", forKey: AppSettingsStore.myCallsignKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.updateRadio(settings.radios[0].id) { $0.host = "127.0.0.1"; $0.port = 8001 }
        XCTAssertEqual(settings.myCallsign, "K0EPI")
        XCTAssertEqual(settings.primaryCallsign, "K0EPI-5")

        let engine = PacketEngine(settings: settings, linkFactory: { [weak self] _ in
            let fresh = KISSLinkLoopback()
            fresh.loopbackEnabled = false
            self?.link = fresh
            return fresh
        })
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = settings.primaryCallsign
        coordinator.appSettings = settings
        coordinator.subscribeToPackets(from: engine)
        defer { withExtendedLifetime((engine, coordinator)) {} }
        engine.connectUsingSettings()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(coordinator.sessionManager.answeredAddresses.map(\.display), ["K0EPI-5"])

        let peer = AX25Address(call: "PEER", ssid: 1)
        let sabm = AX25FrameBuilder.buildSABM(from: peer, to: AX25Address(call: "K0EPI", ssid: 5),
                                              via: DigiPath(), extended: false).encodeAX25()
        link!.injectReceived(KISS.encodeFrame(payload: sabm, port: 0))
        for _ in 0..<100 where (link?.sentData ?? []).isEmpty {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let ua = (link?.sentData ?? []).compactMap { kiss -> AX25.FrameDecodeResult? in
            var parser = KISSFrameParser()
            guard let frame = parser.feedFrames(kiss).first, case .ax25(let ax25) = frame.output else { return nil }
            return AX25.decodeFrame(ax25: ax25)
        }.first
        XCTAssertEqual(ua?.from?.display, "K0EPI-5")
    }
}

/// A radio with no callsign of its own follows the base, and the session
/// layer follows the radio without a view having to tell it.
@MainActor
final class InheritingRadioFollowsBaseTests: XCTestCase {

    func testChangingTheBaseMovesAnInheritingPrimary() async {
        let settings = AppSettingsStore(defaults: TestDefaults.make("InheritingRadio"))
        settings.myCallsign = "K0EPI"
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = settings.primaryCallsign
        coordinator.appSettings = settings
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.localCallsign, "K0EPI")

        settings.myCallsign = "W1ABC"
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(coordinator.localCallsign, "W1ABC")
        XCTAssertEqual(coordinator.sessionManager.localCallsign.display, "W1ABC")
    }
}

/// Receive-side matching over every address the radios transmit as.
final class OwnAddressMatchingTests: XCTestCase {

    func testADigipeatedCopyOfAnyRadiosFrameIsOurEcho() {
        let line = ConsoleLine.packet(from: "K0EPI-7", to: "BEACON", text: "hi", via: ["DRLNOD*"])
        XCTAssertTrue(line.isDigipeatEcho(localCallsigns: ["K0EPI-5", "K0EPI-7"]))
        XCTAssertFalse(line.isDigipeatEcho(localCallsigns: ["K0EPI-5"]))
        XCTAssertFalse(line.isDigipeatEcho(localCallsigns: ["K0EPI"]),
                       "another SSID on the licence is another station")
    }

    func testANodeListingAnyOfOurAddressesIsNotARouteToUs() {
        let row = BpqRoutesScraper.HarvestedLink(anchor: "DRLNOD", neighbor: "K0EPI-7", port: 1, quality: 200, count: 1, isActive: false,
                                                 observedAt: Date())
        let decision = HarvestedRoutePolicy.decide(rows: [row], anchorCanRouteNetRom: true,
                                                   localCallsigns: ["K0EPI-5", "K0EPI-7"])
        XCTAssertTrue(decision.accepted.isEmpty)
        XCTAssertEqual(decision.refused.first?.reason, "that neighbor is this station")
    }
}
