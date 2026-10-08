//
//  BackgroundKeepsBluetoothCallsTests.swift
//  AXTermTests
//
//  Leaving AXTerm on a phone or iPad hung up every call (park rehearsal
//  2026-10-08: DISC from the phone at 11:39:49Z when the operator switched
//  apps). That is right for a network TNC, whose connection iOS drops when it
//  suspends the app, but a Bluetooth TNC stays connected in the background
//  (the app keeps Bluetooth running), so its calls are left up. Operator's
//  approval, 2026-10-08: "Stay up on Bluetooth".
//

import XCTest
@testable import AXTerm

@MainActor
final class BackgroundKeepsBluetoothCallsTests: XCTestCase {

    private let bluetooth = RadioID(rawValue: "tnc4")
    private let network = RadioID(rawValue: "direwolf")

    private func connected(_ coordinator: SessionCoordinator, _ peer: AX25Address, on radio: RadioID) -> AX25Session {
        let session = coordinator.sessionManager.session(for: peer, path: DigiPath(), radio: radio)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)
        XCTAssertEqual(session.state, .connected)
        return session
    }

    func testOnlyAConnectionThatEndsInTheBackgroundSurvivesNot() {
        XCTAssertTrue(BackgroundGoodbye.survivesSuspension(.ble))
        for kind in [RadioTransportKind.tcp, .serial, .modem] {
            XCTAssertFalse(BackgroundGoodbye.survivesSuspension(kind), "\(kind)")
        }
    }

    func testACallOverBluetoothIsLeftUpAndANetworkOneIsClosed() {
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "K0EPI-3"
        let overBluetooth = connected(coordinator, AX25Address(call: "K0EPI", ssid: 4), on: bluetooth)
        let overNetwork = connected(coordinator, AX25Address(call: "K0EPI", ssid: 2), on: network)
        let survives: (RadioID) -> Bool = { [bluetooth] in $0 == bluetooth }

        XCTAssertTrue(coordinator.hasLiveLinks(endingInBackground: survives))
        XCTAssertEqual(coordinator.prepareForTermination(keeping: survives), 1)
        XCTAssertEqual(overBluetooth.state, .connected, "the Bluetooth call carries on")
        XCTAssertEqual(overNetwork.state, .disconnecting, "the network call is closed properly")
    }

    func testNothingToCloseWhenEveryCallIsOverBluetooth() {
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "K0EPI-3"
        _ = connected(coordinator, AX25Address(call: "K0EPI", ssid: 4), on: bluetooth)
        XCTAssertFalse(coordinator.hasLiveLinks(endingInBackground: { [bluetooth] in $0 == bluetooth }),
                       "no goodbye to say, so no background task either")
    }
}
