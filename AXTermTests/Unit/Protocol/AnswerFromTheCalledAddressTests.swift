//
//  AnswerFromTheCalledAddressTests.swift
//  AXTermTests
//
//  Park rehearsal 2026-10-08, findings 32 and 33. A (705) called K0EPI-3 as
//  K0EPI-2 and hung up before the phone heard it, which left A a session
//  record for K0EPI-3 that had never connected. The phone then called the
//  mailbox, K0EPI-4. A reused that record and answered UA from K0EPI-2, and
//  the phone took a UA from K0EPI-2 as the answer to its call to K0EPI-4.
//
//  AX.25 identifies a link by both addresses. A SABM is answered from the
//  address it was sent to, and a UA from any other address is not the answer
//  to our SABM.
//

import XCTest
@testable import AXTerm

@MainActor
final class AnswerFromTheCalledAddressTests: XCTestCase {

    private let station = AX25Address(call: "K0EPI", ssid: 2)   // A (705)
    private let mailbox = AX25Address(call: "K0EPI", ssid: 4)   // A's mailbox
    private let phone = AX25Address(call: "K0EPI", ssid: 3)

    private func stationA() -> AX25SessionManager {
        let manager = AX25SessionManager(localCallsign: station, clock: AX25VirtualClock())
        manager.setServiceAddress(mailbox, for: "bbs")
        return manager
    }

    // MARK: Finding 32, the station answering

    func testACallToTheMailboxAfterAnAbandonedCallIsAnsweredFromTheMailbox() throws {
        let manager = stationA()
        _ = manager.connect(to: phone, path: DigiPath(), radio: .primary)
        let abandoned = try XCTUnwrap(manager.existingSession(for: phone, path: DigiPath(), radio: .primary))
        _ = manager.disconnect(session: abandoned)
        XCTAssertNotEqual(abandoned.state, .connected)

        let ua = try XCTUnwrap(manager.handleInboundSABM(from: phone, to: mailbox, path: DigiPath(),
                                                         radio: .primary))

        XCTAssertEqual(ua.displayInfo, "UA")
        XCTAssertEqual(ua.source.display, "K0EPI-4", "answered from the address the SABM was sent to")
        let link = try XCTUnwrap(manager.existingSession(for: phone, path: DigiPath(), radio: .primary))
        XCTAssertEqual(link.localAddress.display, "K0EPI-4")
        XCTAssertEqual(link.state, .connected)
        XCTAssertFalse(link.isInitiator)
    }

    /// A live link to the caller on another of our addresses is not taken
    /// over: the call is refused with DM from the address it was made to.
    func testALiveLinkOnAnotherAddressIsLeftAloneAndTheCallRefused() throws {
        let manager = stationA()
        _ = manager.connect(to: phone, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundUA(from: phone, path: DigiPath(), radio: .primary)
        let live = try XCTUnwrap(manager.existingSession(for: phone, path: DigiPath(), radio: .primary))
        XCTAssertEqual(live.state, .connected)

        let answer = try XCTUnwrap(manager.handleInboundSABM(from: phone, to: mailbox, path: DigiPath(),
                                                             radio: .primary))

        XCTAssertEqual(answer.displayInfo, "DM")
        XCTAssertEqual(answer.source.display, "K0EPI-4")
        XCTAssertEqual(live.state, .connected)
        XCTAssertEqual(live.localAddress.display, "K0EPI-2")
    }

    /// A call to the address the record already has is the same link.
    func testACallToTheSameAddressStillReusesTheRecord() throws {
        let manager = stationA()
        _ = manager.connect(to: phone, path: DigiPath(), radio: .primary)
        let abandoned = try XCTUnwrap(manager.existingSession(for: phone, path: DigiPath(), radio: .primary))
        _ = manager.disconnect(session: abandoned)

        let ua = try XCTUnwrap(manager.handleInboundSABM(from: phone, to: station, path: DigiPath(),
                                                         radio: .primary))

        XCTAssertEqual(ua.displayInfo, "UA")
        XCTAssertEqual(ua.source.display, "K0EPI-2")
    }

    // MARK: Finding 33, the caller

    func testAUAFromAnotherSSIDDoesNotAnswerOurCall() throws {
        let manager = AX25SessionManager(localCallsign: phone, clock: AX25VirtualClock())
        _ = manager.connect(to: mailbox, path: DigiPath(), radio: .primary)
        let call = try XCTUnwrap(manager.existingSession(for: mailbox, path: DigiPath(), radio: .primary))

        _ = manager.handleInboundUA(from: station, path: DigiPath(), radio: .primary)

        XCTAssertEqual(call.state, .connecting, "a UA from K0EPI-2 is not the mailbox answering")
        XCTAssertEqual(call.remoteAddress.display, "K0EPI-4")

        _ = manager.handleInboundUA(from: mailbox, path: DigiPath(), radio: .primary)
        XCTAssertEqual(call.state, .connected)
    }
}
