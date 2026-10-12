//
//  MailboxTalkTests.swift
//  AXTermTests
//
//  TALK at the mailbox: `T` pages the operator; answered, the call goes to
//  the operator's terminal on the caller's own link, and `/EX` or the
//  operator ending the chat brings the caller back to the mailbox prompt.
//

import GRDB
import XCTest
@testable import AXTerm

@MainActor
final class MailboxTalkTests: XCTestCase {

    private var coordinator: SessionCoordinator!
    private var service: BBSService!
    private var caller: BBSSimulatedCaller!
    private var terminal = ""

    override func setUp() async throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let settings = BBSSettings(defaults: TestDefaults.make("mailbox-talk"))
        settings.onAir = true
        settings.callsign = "K0EPI-4"
        coordinator = SessionCoordinator()
        let simulated = BBSSimulatedCaller(manager: coordinator.sessionManager, address: AX25Address(call: "K0EPI", ssid: 3),
                                           mailbox: AX25Address(call: "K0EPI", ssid: 4))
        caller = simulated
        coordinator.sessionManager.onSendFrame = { [weak simulated] in simulated?.outbox.append($0) }
        coordinator.onFrameHandedToRadio = { [weak simulated] in simulated?.outbox.append($0) }
        coordinator.sessionManager.onDataReceived = { [weak self] _, data in
            self?.terminal += String(decoding: data, as: UTF8.self)
        }
        service = BBSService(store: SQLiteBBSMessageStore(dbQueue: queue), settings: settings,
                             coordinator: coordinator,
                             sendFrames: { [weak simulated] in simulated?.outbox.append(contentsOf: $0) },
                             stationCallsign: { "K0EPI" }, isWinlinkP2PArmed: { false },
                             winlinkP2PCallsign: { "" }, linkBytesPerSecond: { 1_000_000 })
        service.attach()
        caller.connect()
        _ = await caller.pump { self.caller.text.contains("not met you before") }
        caller.type("A")
        _ = await caller.pump { self.caller.text.hasSuffix(">\r") }
    }

    override func tearDown() async throws {
        service?.shutdown(reason: "test over")
        service?.detach()
    }

    private func page() async throws -> TalkRouter.Page {
        caller.clearReceived()
        caller.type("T")
        _ = await caller.pump { !self.coordinator.talkRouter.pages.isEmpty }
        return try XCTUnwrap(coordinator.talkRouter.pages.first)
    }

    private func chatting() async throws {
        coordinator.talkRouter.answer(try await page())
        _ = await caller.pump { self.caller.text.contains("talking with the operator") }
        caller.clearReceived()
    }

    func testTPagesTheOperator() async throws {
        let page = try await page()
        XCTAssertEqual(page.caller, "K0EPI-3")
        XCTAssertEqual(page.door, .mailbox)
        XCTAssertTrue(caller.text.contains("Paging the operator"), caller.text)
    }

    func testAnsweredTheChatGoesToTheTerminal() async throws {
        try await chatting()
        caller.type("are we still connected")
        _ = await caller.pump(timeout: 1) { self.terminal.contains("are we still connected") }
        XCTAssertTrue(terminal.contains("are we still connected"), terminal)
        XCTAssertFalse(caller.text.contains("? ARE"), "the mailbox does not read the chat: \(caller.text)")
        XCTAssertNotNil(service.live, "the call is still the mailbox's, lent out")
    }

    func testExBringsTheCallerBackToTheMailbox() async throws {
        try await chatting()
        caller.type("/ex")
        _ = await caller.pump { self.caller.text.contains("Back at the mailbox.") }
        XCTAssertTrue(caller.text.contains("Back at the mailbox."), caller.text)
        XCTAssertNil(coordinator.talkRouter.chat)
        caller.clearReceived()
        caller.type("H")
        _ = await caller.pump { self.caller.text.contains("this help") }
        XCTAssertTrue(caller.text.contains("this help"), caller.text)
    }

    func testTheOperatorEndingBringsTheCallerBack() async throws {
        try await chatting()
        coordinator.talkRouter.endChat()
        _ = await caller.pump { self.caller.text.contains("Back at the mailbox.") }
        XCTAssertTrue(caller.text.contains("The operator left the chat."), caller.text)
        XCTAssertTrue(caller.text.contains("Back at the mailbox."), caller.text)
    }

    func testNotNowBringsThePromptBack() async throws {
        coordinator.talkRouter.decline(try await page())
        _ = await caller.pump { self.caller.text.contains("isn't at the station") }
        XCTAssertTrue(caller.text.contains("The operator isn't at the station. S leaves them mail."), caller.text)
        XCTAssertTrue(caller.text.hasSuffix(">\r"), caller.text)
    }

    func testTheLinkDroppingEndsTheCall() async throws {
        try await chatting()
        caller.disconnect()
        _ = await caller.pump(timeout: 1) { self.service.live == nil }
        XCTAssertNil(coordinator.talkRouter.chat)
        XCTAssertNil(service.live, "the mailbox's call ended with the link")
    }
}
