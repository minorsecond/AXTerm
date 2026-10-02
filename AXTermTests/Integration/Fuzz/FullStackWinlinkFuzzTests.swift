//
//  FullStackWinlinkFuzzTests.swift
//  AXTermTests
//
//  Winlink peer-to-peer exchanges between two complete stations over an
//  impaired link: A's runner calls B through WinlinkAX25Transport, and B
//  answers the inbound link the way the mail view does. Each station has
//  its own Winlink store and a random Outbox, with attachments, some of it
//  addressed to the peer and some not. Outages, disconnects and aborts on
//  either side land at random moments.
//
//  What must hold:
//  - both runners finish; nothing is left "running";
//  - a message marked sent on one side is in the other's inbox, identical
//    (subject, recipients, body, every attachment);
//  - anything in an inbox is identical to what was queued, once;
//  - mail not marked sent is still queued, never lost or stuck "sending";
//  - mail not addressed to the peer never leaves;
//  - with no action on a mild channel, everything addressed to the peer is
//    delivered both ways.
//
//  Report: AXTermStress/fullstack-winlink.txt in the test host's temporary
//  directory.
//

import XCTest
import GRDB
@testable import AXTerm

@MainActor
final class FullStackWinlinkFuzzTests: XCTestCase {

    private enum Action: String { case none, outage, disconnectCaller, disconnectAnswerer, abortCaller, abortAnswerer }

    func testRandomPeerToPeerExchangesOverAnImpairedLink() async throws {
        var report: [String] = []
        var problems: [String] = []
        for seed in FullStackFuzz.seeds(normal: 3) {
            let (lines, found) = try await runScenario(seed: seed)
            report += lines
            problems += found
        }
        StressReport.write(report + ["", "Problems: \(problems.count)"] + problems, name: "fullstack-winlink")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    // MARK: Helpers

    private func makeStore() throws -> SQLiteWinlinkStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteWinlinkStore(dbQueue: queue)
    }

    private func transport(_ station: FuzzStation, to destination: AX25Address,
                           radio: RadioID? = nil) -> WinlinkAX25Transport {
        WinlinkAX25Transport(
            sessionManager: station.coordinator.sessionManager,
            sendFrames: { [weak coordinator = station.coordinator] frames in
                frames.forEach { coordinator?.sendFrame($0) }
            },
            destination: destination,
            radio: radio ?? station.coordinator.primaryRadioID,
            connectTimeout: 40)
    }

    private func message(mid: String, from: String, to: [String], pick: inout FuzzPicker) -> WinlinkB2Message {
        let attachments = (0..<pick.pick([0, 0, 1, 2])).map { n in
            WinlinkB2Message.Attachment(name: "att\(n).bin", data: pick.bytes(pick.pick([0, 10, 300, 2000, 6000])))
        }
        let words = (0..<pick.int(0...60)).map { _ in pick.pick(["CQ", "test", "73", "QSL", "net", "photo", "K0EPI"]) }
        return WinlinkB2Message(
            mid: mid, date: Date(), type: .privateMessage, from: from, to: to, cc: [],
            subject: "Fuzz \(mid)", mbo: from,
            body: Data((words.joined(separator: " ") + "\r\n").utf8),
            attachments: attachments)
    }

    private func same(_ a: WinlinkB2Message, _ b: WinlinkB2Message) -> Bool {
        a.mid == b.mid && a.subject == b.subject && a.to == b.to && a.body == b.body
            && a.attachments.map(\.name) == b.attachments.map(\.name)
            && a.attachments.map(\.data) == b.attachments.map(\.data)
    }

    // MARK: One scenario

    private func runScenario(seed: UInt64) async throws -> (report: [String], problems: [String]) {
        var pick = FuzzPicker(seed: seed ^ 0x77)
        var impairment = FuzzKISSLink.Impairment()
        impairment.loss = pick.pick([0, 0, 0.02, 0.05, 0.1])
        impairment.duplicate = pick.pick([0, 0, 0.02, 0.05])
        impairment.jitter = pick.pick([0, 0.02, 0.08])
        impairment.chunked = pick.chance(0.5)
        let mild = impairment.loss <= 0.05
        let action = pick.pick([Action.none, .none, .none, .outage, .disconnectCaller, .disconnectAnswerer,
                                .abortCaller, .abortAnswerer])

        let a = FuzzStation(callsign: "K0AAA-1", seed: seed &* 2)
        let b = FuzzStation(callsign: "K0BBB-2", seed: seed &* 2 &+ 1)
        defer { a.tearDown(); b.tearDown() }
        a.link.impairment = impairment
        b.link.impairment = impairment
        a.connectLink(to: b)
        b.connectLink(to: a)

        let storeA = try makeStore()
        let storeB = try makeStore()
        let runnerA = WinlinkSessionRunner(store: storeA)
        let runnerB = WinlinkSessionRunner(store: storeB)

        // Outboxes: to the peer by callsign or account, or to someone else.
        var sentByA: [WinlinkB2Message] = []
        var sentByB: [WinlinkB2Message] = []
        for i in 0..<pick.int(0...4) {
            let to = pick.pick([["K0BBB-2"], ["K0BBB"], ["N0CALL"], ["K0BBB-2", "W1AW"]])
            let m = message(mid: String(format: "A%02llu%02d%07d", seed % 100, i, 0).prefix(12).description,
                            from: "K0AAA", to: to, pick: &pick)
            try storeA.saveDraft(m)
            try storeA.queueDraft(mid: m.mid)
            sentByA.append(m)
        }
        for i in 0..<pick.int(0...3) {
            let to = pick.pick([["K0AAA-1"], ["K0AAA"], ["N0CALL"]])
            let m = message(mid: String(format: "B%02llu%02d%07d", seed % 100, i, 0).prefix(12).description,
                            from: "K0BBB", to: to, pick: &pick)
            try storeB.saveDraft(m)
            try storeB.queueDraft(mid: m.mid)
            sentByB.append(m)
        }

        var report = ["seed \(seed): \(impairment) action=\(action.rawValue) A queued \(sentByA.count), B queued \(sentByB.count)"]
        var problems: [String] = []
        let started = Date()
        func problem(_ text: String) {
            problems.append("seed \(seed): \(text)")
            if FullStackFuzz.tracing { problems += FullStackFuzz.trace(a, b, since: started, limit: 200) }
        }

        // B answers inbound calls as a P2P peer with the production decision
        // and the same wait WinlinkMailView uses: a SABM that resets the link
        // under a running exchange is answered once that exchange has ended.
        var answerTasks: [Task<Void, Never>] = []
        b.coordinator.onInboundSessionConnected = { [weak self] session in
            guard let self else { return }
            let decision = WinlinkP2PListener(
                isArmed: true, myCallsign: "K0BBB-2",
                isExchangeRunning: runnerB.isRunning, contestedBy: nil,
                runningExchangePeer: runnerB.currentPeer)
                .decide(called: session.localAddress.display, isInitiator: session.isInitiator,
                        caller: session.remoteAddress.display)
            guard decision == .answer || decision == .answerWhenFree else { return }
            let peer = session.remoteAddress.display.uppercased()
            let t = self.transport(b, to: session.remoteAddress, radio: session.radio)
            answerTasks.append(Task { @MainActor in
                if decision == .answerWhenFree {
                    guard await runnerB.waitUntilIdle(timeout: 15), session.state == .connected else { return }
                }
                _ = await runnerB.runExchange(transport: t, myCallsign: "K0BBB-2", password: nil,
                                              gatewayName: peer, transportName: "P2P",
                                              role: .answering, peer: peer)
            })
        }

        let callerTask = Task { @MainActor in
            await runnerA.runExchange(transport: self.transport(a, to: b.address), myCallsign: "K0AAA-1",
                                      password: nil, gatewayName: "K0BBB-2", transportName: "P2P",
                                      peer: "K0BBB-2")
        }

        if action != .none {
            try? await Task.sleep(nanoseconds: UInt64(pick.uniform(0.5, 6) * 1e9))
            switch action {
            case .outage:
                a.link.silenced = true
                b.link.silenced = true
                try? await Task.sleep(nanoseconds: UInt64(pick.uniform(1, 4) * 1e9))
                a.link.silenced = false
                b.link.silenced = false
            case .disconnectCaller, .disconnectAnswerer:
                let station = action == .disconnectCaller ? a : b
                if let session = station.session,
                   let disc = station.coordinator.sessionManager.disconnect(session: session) {
                    station.coordinator.sendFrame(disc)
                }
            case .abortCaller:
                runnerA.abort()
            case .abortAnswerer:
                runnerB.abort()
            case .none:
                break
            }
        }

        let summaryA = await callerTask.value
        let finished = await FullStackFuzz.wait(150) { !runnerA.isRunning && !runnerB.isRunning }
        for task in answerTasks { _ = await task.value }
        report.append("  caller: \(summaryA.failureReason.map { "failed: \($0)" } ?? (summaryA.aborted ? "aborted" : "ok")) sent \(summaryA.sentMIDs.count) received \(summaryA.receivedMIDs.count)")
        if !finished {
            problem("a runner is still running after 150 s (A \(runnerA.isRunning), B \(runnerB.isRunning))")
        }

        // Every message, both directions.
        func check(_ queued: [WinlinkB2Message], from senderStore: SQLiteWinlinkStore,
                   to receiverStore: SQLiteWinlinkStore, peerCall: String, label: String) throws -> (delivered: Int, owed: Int) {
            var delivered = 0
            var owed = 0
            for m in queued {
                let forPeer = WinlinkPeerCall.isAddressed(m, to: peerCall)
                let state = try senderStore.message(mid: m.mid)?.state.state
                let arrived = try receiverStore.message(mid: m.mid)
                if forPeer { owed += 1 }
                if let arrived {
                    delivered += 1
                    if !same(arrived.message, m) { problem("\(label) \(m.mid) arrived different") }
                    if !forPeer { problem("\(label) \(m.mid) was not for the peer but was delivered") }
                }
                switch state {
                case .sent:
                    if arrived == nil { problem("\(label) \(m.mid) is marked sent but never arrived") }
                case .queued:
                    break
                default:
                    problem("\(label) \(m.mid) ended \(String(describing: state)), neither sent nor queued")
                }
                if !forPeer, state != .queued { problem("\(label) \(m.mid) for someone else ended \(String(describing: state))") }
            }
            return (delivered, owed)
        }
        let ab = try check(sentByA, from: storeA, to: storeB, peerCall: "K0BBB-2", label: "A>B")
        let ba = try check(sentByB, from: storeB, to: storeA, peerCall: "K0AAA-1", label: "B>A")
        report.append("  A>B delivered \(ab.delivered)/\(ab.owed), B>A delivered \(ba.delivered)/\(ba.owed)")
        if action == .none, mild, ab.delivered < ab.owed || ba.delivered < ba.owed {
            problem("no action on a mild channel (\(impairment)) but not everything arrived: A>B \(ab.delivered)/\(ab.owed), B>A \(ba.delivered)/\(ba.owed); caller \(summaryA.failureReason ?? "ok")")
        }
        return (report, problems)
    }
}
