//
//  TalkCoordinatorTests.swift
//  AXTermTests
//
//  TALK at the node, end to end through the station: the page, the chat on
//  the caller's own link in the operator's terminal, and the way back.
//

import XCTest
@testable import AXTerm

@MainActor
final class TalkCoordinatorTests: XCTestCase {

    private let user = AX25Address(call: "K0EPI", ssid: 3)
    private let nodeCall = AX25Address(call: "K0EPI", ssid: 7)
    private var caller: BBSSimulatedCaller!
    private var terminal = ""

    /// What the station sent the caller, as text.
    private var said: String { caller.text }

    private func station() async -> SessionCoordinator {
        let settings = AppSettingsStore(defaults: TestDefaults.make("talk-coordinator"))
        settings.myCallsign = "K0EPI"
        settings.netRomNodeAlias = "EPINOD"
        settings.netRomAcceptInbound = true
        settings.netRomNodeSSID = 7
        let coordinator = SessionCoordinator()
        coordinator.appSettings = settings
        coordinator.applyNetRomNodeSettings(settings)
        // Setting appSettings starts the radios' set-up, which closes links
        // on radios it does not know; let it settle before the call.
        await spin(0.3)
        let simulated = BBSSimulatedCaller(manager: coordinator.sessionManager, address: user, mailbox: nodeCall)
        caller = simulated
        coordinator.onFrameHandedToRadio = { [weak simulated] in simulated?.outbox.append($0) }
        coordinator.sessionManager.onSendFrame = { [weak simulated] in simulated?.outbox.append($0) }
        coordinator.sessionManager.onDataReceived = { [weak self] _, data in
            self?.terminal += String(decoding: data, as: UTF8.self)
        }
        simulated.connect()
        return coordinator
    }

    private func type(_ line: String, to coordinator: SessionCoordinator) {
        caller.type(line)
    }

    private func spin(_ seconds: Double = 0.2) async {
        if let caller {
            _ = await caller.pump(timeout: seconds) { false }
        } else {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        }
    }

    private func paged() async -> SessionCoordinator {
        let coordinator = await station()
        type("i", to: coordinator)
        await spin()
        type("t", to: coordinator)
        await spin()
        return coordinator
    }

    func testTalkPagesTheOperator() async {
        let coordinator = await paged()
        XCTAssertEqual(coordinator.talkRouter.pages.map(\.caller), ["K0EPI-3"])
        XCTAssertEqual(coordinator.talkRouter.pages.first?.door, .node)
        XCTAssertTrue(said.contains("Paging the operator"), said)
    }

    func testASecondTalkWhilePagedIsOnePage() async {
        let coordinator = await paged()
        type("t", to: coordinator)
        await spin()
        XCTAssertEqual(coordinator.talkRouter.pages.count, 1)
    }

    func testAnsweringPutsTheCallerThroughToTheTerminal() async throws {
        let coordinator = await paged()
        let page = try XCTUnwrap(coordinator.talkRouter.pages.first)
        caller.clearReceived()
        coordinator.talkRouter.answer(page)
        await spin()
        XCTAssertTrue(said.contains("You are talking with the operator. /EX takes you back."), said)
        XCTAssertEqual(coordinator.talkRouter.chat?.caller, "K0EPI-3")
        XCTAssertEqual(coordinator.talkRouter.chat?.session.localAddress, nodeCall)
        XCTAssertTrue(coordinator.talkRouter.pages.isEmpty)

        caller.clearReceived()
        type("hello from the road", to: coordinator)
        await spin()
        XCTAssertTrue(terminal.contains("hello from the road"), terminal)
        XCTAssertFalse(said.contains("EPINOD:K0EPI-7}"), "the node does not answer chat: \(said)")
    }

    func testExTakesTheCallerBackToTheNode() async throws {
        let coordinator = await paged()
        coordinator.talkRouter.answer(try XCTUnwrap(coordinator.talkRouter.pages.first))
        await spin()
        caller.clearReceived()
        type("/ex", to: coordinator)
        await spin()
        XCTAssertTrue(said.contains("Back at the node."), said)
        XCTAssertNil(coordinator.talkRouter.chat)
        caller.clearReceived()
        type("i", to: coordinator)
        await spin()
        XCTAssertTrue(said.contains("Node EPINOD:K0EPI-7"), said)
    }

    func testTheOperatorEndingTheChatReturnsTheCaller() async throws {
        let coordinator = await paged()
        coordinator.talkRouter.answer(try XCTUnwrap(coordinator.talkRouter.pages.first))
        await spin()
        caller.clearReceived()
        coordinator.talkRouter.endChat()
        await spin()
        XCTAssertTrue(said.contains("The operator left the chat."), said)
        XCTAssertTrue(said.contains("Back at the node."), said)
        XCTAssertNil(coordinator.talkRouter.chat)
    }

    func testNotNowBringsThePromptBack() async throws {
        let coordinator = await paged()
        caller.clearReceived()
        coordinator.talkRouter.decline(try XCTUnwrap(coordinator.talkRouter.pages.first))
        await spin()
        XCTAssertTrue(said.contains("The operator isn't at the station."), said)
        XCTAssertTrue(coordinator.talkRouter.pages.isEmpty)
        caller.clearReceived()
        type("i", to: coordinator)
        await spin()
        XCTAssertTrue(said.contains("Node EPINOD:K0EPI-7"), said)
    }

    func testNobodyAnsweringInTimeBringsThePromptBack() async {
        let coordinator = await station()
        coordinator.talkPageTimeout = .milliseconds(300)
        type("t", to: coordinator)
        await spin(0.8)
        XCTAssertTrue(said.contains("The operator isn't at the station."), said)
        XCTAssertTrue(coordinator.talkRouter.pages.isEmpty)
    }

    func testTheLinkDroppingEndsTheChat() async throws {
        let coordinator = await paged()
        coordinator.talkRouter.answer(try XCTUnwrap(coordinator.talkRouter.pages.first))
        await spin()
        caller.disconnect()
        await spin()
        XCTAssertNil(coordinator.talkRouter.chat)
    }

    func testAPageForACallerWhoLeftGoesAway() async {
        let coordinator = await paged()
        XCTAssertEqual(coordinator.talkRouter.pages.count, 1)
        caller.disconnect()
        await spin()
        XCTAssertTrue(coordinator.talkRouter.pages.isEmpty)
    }
}
