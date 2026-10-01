//
//  TerminalDestinationBindingTests.swift
//  AXTermTests
//
//  Which session the terminal's compose bar is bound to, and when.
//
//  Live RF test 2026-09-30, station B (K0EPI-3), connected to by K0EPI-2:
//  typing K0EPI-2 into the To field stopped at "K". The first keystroke set
//  the destination to "K", and with no session for "K" the terminal fell
//  back to any connected session, so the field locked as connected while
//  showing "K". Send then stayed disabled, because "K" is not a callsign,
//  until the operator picked the session in the sidebar (bugs 3 and 4).
//
//  A destination the operator sets binds only the session for that station.
//  Taking up whichever session is connected is for an inbound connection or
//  a terminal with nothing chosen, and then the destination follows the
//  session so the bar names the station it is actually talking to.
//

import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class TerminalDestinationBindingTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 2)

    private func makeTerminal(_ label: String) -> (ObservableTerminalTxViewModel, AX25SessionManager) {
        let defaults = TestDefaults.make(label)
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 3))
        let terminal = ObservableTerminalTxViewModel(client: PacketEngine(settings: settings),
                                                     settings: settings, sourceCall: "K0EPI-3",
                                                     sessionManager: manager)
        return (terminal, manager)
    }

    private func connectedSession(_ manager: AX25SessionManager, to address: AX25Address) -> AX25Session {
        let session = manager.session(for: address)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)
        XCTAssertEqual(session.state, .connected, "precondition")
        return session
    }

    // MARK: - Typing a destination (bug 3)

    /// The field case: "K" names no session, so nothing is bound and the
    /// field stays editable.
    func testAPartialCallsignBindsNoSession() {
        let (terminal, manager) = makeTerminal("DestinationBindingPartial")
        _ = connectedSession(manager, to: peer)

        terminal.destinationCall.wrappedValue = "K"

        XCTAssertNil(terminal.currentSession,
                     "\"K\" bound the terminal to the session with K0EPI-2 and locked the field")
    }

    /// The whole callsign names the live session, which is then the one the
    /// bar targets.
    func testTheFullCallsignBindsItsSession() {
        let (terminal, manager) = makeTerminal("DestinationBindingFull")
        let session = connectedSession(manager, to: peer)

        terminal.destinationCall.wrappedValue = "K"
        terminal.destinationCall.wrappedValue = "K0EPI-2"

        XCTAssertEqual(terminal.currentSession?.id, session.id)
        XCTAssertEqual(terminal.sessionState, .connected)
    }

    /// Clearing the To field lets go of the session (it carries on in the
    /// sidebar) instead of binding straight back to it.
    func testClearingTheDestinationUnbinds() {
        let (terminal, manager) = makeTerminal("DestinationBindingClear")
        _ = connectedSession(manager, to: peer)
        terminal.destinationCall.wrappedValue = "K0EPI-2"
        XCTAssertNotNil(terminal.currentSession, "precondition")

        terminal.destinationCall.wrappedValue = ""

        XCTAssertNil(terminal.currentSession, "the cleared field locked again on the same session")
    }

    // MARK: - Taking up a session nobody chose (bug 4)

    /// With nothing chosen, the terminal takes up the connected session and
    /// names it.
    func testRefreshTakesUpTheConnectedSessionWhenNothingIsChosen() {
        let (terminal, manager) = makeTerminal("DestinationBindingAdoptEmpty")
        let session = connectedSession(manager, to: peer)

        terminal.refreshCurrentSession()

        XCTAssertEqual(terminal.currentSession?.id, session.id)
        XCTAssertEqual(terminal.viewModel.destinationCall, "K0EPI-2")
    }

    /// A destination with no session at all ("K", left by the operator) must
    /// not hide the session that is actually up. The terminal takes it up and
    /// the destination follows it, so Send goes to the station the bar shows.
    func testTakingUpASessionReplacesADestinationThatHasNoSession() {
        let (terminal, manager) = makeTerminal("DestinationBindingAdoptStale")
        let session = connectedSession(manager, to: peer)
        terminal.destinationCall.wrappedValue = "K"

        terminal.refreshCurrentSession()

        XCTAssertEqual(terminal.currentSession?.id, session.id)
        XCTAssertEqual(terminal.viewModel.destinationCall, "K0EPI-2",
                       "the bar was bound to K0EPI-2 while still naming \"K\"")
        terminal.composeText.wrappedValue = "B to A test 1"
        XCTAssertTrue(terminal.canSend, "Send stayed disabled over a live session")
    }

    /// A destination that has its own session keeps it, even while another
    /// station is connected.
    func testAChosenStationIsNotReplacedByAnotherSession() {
        let (terminal, manager) = makeTerminal("DestinationBindingKeepChosen")
        _ = connectedSession(manager, to: peer)
        let chosen = connectedSession(manager, to: AX25Address(call: "N0CALL", ssid: 1))
        terminal.destinationCall.wrappedValue = "N0CALL-1"

        terminal.refreshCurrentSession()

        XCTAssertEqual(terminal.currentSession?.id, chosen.id)
        XCTAssertEqual(terminal.viewModel.destinationCall, "N0CALL-1")
    }

    /// The field sequence end to end: "K" left in the bar, then K0EPI-2
    /// connects in. The terminal takes the session up as it connects, names
    /// it, and Send is available without a trip to the sidebar.
    func testAnInboundConnectionEnablesSendOverAStaleDestination() async {
        let (terminal, manager) = makeTerminal("DestinationBindingInbound")
        terminal.setupSessionCallbacks()
        terminal.destinationCall.wrappedValue = "K"
        terminal.composeText.wrappedValue = "B to A test 1"

        _ = manager.handleInboundSABM(from: peer, to: AX25Address(call: "K0EPI", ssid: 3),
                                      path: DigiPath(), radio: .primary)
        for _ in 0..<100 where terminal.viewModel.destinationCall != "K0EPI-2" {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(terminal.sessionState, .connected)
        XCTAssertEqual(terminal.viewModel.destinationCall, "K0EPI-2")
        XCTAssertTrue(terminal.canSend, "Send stayed disabled over a live session")
    }

    // MARK: - Data arriving on another session

    /// Talking to K0EPI-2 while K0EPI-4 is also connected: a line from
    /// K0EPI-4 used to switch the terminal to its session but leave the To
    /// field on K0EPI-2, so the next thing typed was addressed to one station
    /// and sent down the other's link. The line still reaches the console
    /// under K0EPI-4; what the operator is talking to stays put.
    func testDataFromAnotherStationLeavesTheChosenSessionAlone() {
        let (terminal, manager) = makeTerminal("DestinationBindingOtherData")
        terminal.setupSessionCallbacks()
        let chosen = connectedSession(manager, to: peer)
        let other = connectedSession(manager, to: AX25Address(call: "K0EPI", ssid: 4))
        terminal.destinationCall.wrappedValue = "K0EPI-2"
        XCTAssertEqual(terminal.currentSession?.id, chosen.id, "precondition")

        manager.onDataReceived?(other, Data("hello from 4\r".utf8))

        XCTAssertEqual(terminal.currentSession?.id, chosen.id,
                       "a line from K0EPI-4 took the terminal away from K0EPI-2")
        XCTAssertEqual(terminal.viewModel.destinationCall, "K0EPI-2")
    }

    /// With nothing chosen, the first station to send data is the one the
    /// terminal takes up, and the To field names it so Send goes there.
    func testDataTakesUpItsSessionWhenNothingIsChosen() {
        let (terminal, manager) = makeTerminal("DestinationBindingFirstData")
        terminal.setupSessionCallbacks()
        let other = connectedSession(manager, to: AX25Address(call: "K0EPI", ssid: 4))
        terminal.setCurrentSession(nil)

        manager.onDataReceived?(other, Data("hello from 4\r".utf8))

        XCTAssertEqual(terminal.currentSession?.id, other.id)
        XCTAssertEqual(terminal.viewModel.destinationCall, "K0EPI-4",
                       "the terminal took up K0EPI-4's session with another station in the To field")
    }

    /// A chosen session that has since dropped gives way to the live one
    /// sending data, and the To field follows it.
    func testDataReplacesASessionThatDropped() {
        let (terminal, manager) = makeTerminal("DestinationBindingDroppedData")
        terminal.setupSessionCallbacks()
        let chosen = connectedSession(manager, to: peer)
        terminal.destinationCall.wrappedValue = "K0EPI-2"
        XCTAssertEqual(terminal.currentSession?.id, chosen.id, "precondition")
        _ = chosen.stateMachine.handle(event: .receivedDM)
        XCTAssertNotEqual(chosen.state, .connected, "precondition")
        let other = connectedSession(manager, to: AX25Address(call: "K0EPI", ssid: 4))

        manager.onDataReceived?(other, Data("hello from 4\r".utf8))

        XCTAssertEqual(terminal.currentSession?.id, other.id)
        XCTAssertEqual(terminal.viewModel.destinationCall, "K0EPI-4")
    }
}
