//
//  TalkTerminalTests.swift
//  AXTermTests
//
//  The operator's terminal during a TALK chat stays on the caller's own
//  link. The terminal finds a session by the remote callsign, and the
//  caller may have another link up (the iPad held EPINOD and K0EPI-4 at
//  once on 2026-10-12): without the pin the operator's reply could go out
//  on the mailbox's link instead.
//

import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class TalkTerminalTests: XCTestCase {

    private let caller = AX25Address(call: "K0EPI", ssid: 3)
    private let mailbox = AX25Address(call: "K0EPI", ssid: 4)
    private let node = AX25Address(call: "K0EPI", ssid: 7)

    private func twoLinks() throws -> (ObservableTerminalTxViewModel, AX25SessionManager, AX25Session) {
        let settings = AppSettingsStore(defaults: TestDefaults.make("talk-terminal"))
        settings.myCallsign = "K0EPI"
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 2), clock: AX25VirtualClock())
        manager.setServiceAddress(mailbox, for: "bbs")
        manager.setServiceAddress(node, for: "netromNodeCall")
        _ = manager.handleInboundSABM(from: caller, to: mailbox, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundSABM(from: caller, to: node, path: DigiPath(), radio: .primary)
        let talk = try XCTUnwrap(manager.existingSession(for: caller, path: DigiPath(), radio: .primary, local: node))
        let model = ObservableTerminalTxViewModel(client: PacketEngine(settings: settings), settings: settings,
                                                  sourceCall: "K0EPI-2", sessionManager: manager)
        return (model, manager, talk)
    }

    func testPinnedTheTerminalIsOnTheTalkLink() throws {
        let (model, _, talk) = try twoLinks()
        model.pinTalk(to: talk)
        XCTAssertTrue(model.currentSession === talk)
        XCTAssertEqual(model.viewModel.destinationCall, "K0EPI-3")
        model.destinationCall.wrappedValue = "K0EPI-3"
        XCTAssertTrue(model.currentSession === talk, "a fresh look at the destination keeps the talk link")
    }

    func testTheOperatorsReplyGoesOutOnTheTalkLink() throws {
        let (model, manager, talk) = try twoLinks()
        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }
        model.pinTalk(to: talk)
        let frames = model.sendConnected(payload: Data("hello\r".utf8), displayInfo: "hello")
        XCTAssertFalse((frames + sent).isEmpty)
        XCTAssertTrue((frames + sent).allSatisfy { $0.source == self.node }, "\((frames + sent).map(\.source.display))")
    }

    func testUnpinnedTheTerminalChoosesAsBefore() throws {
        let (model, _, talk) = try twoLinks()
        model.pinTalk(to: talk)
        model.unpinTalk()
        XCTAssertNil(model.pinnedTalk)
    }
}
