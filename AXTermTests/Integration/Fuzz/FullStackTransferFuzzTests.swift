//
//  FullStackTransferFuzzTests.swift
//  AXTermTests
//
//  Random AXDP and YAPP transfers and chat between two complete stations
//  over an impaired link, with pauses, cancels, declines, outages and
//  disconnects thrown in at random moments. Production code from KISS
//  framing up; see FullStackFuzzSupport.
//
//  What must hold for every operation:
//  - both ends of a transfer reach a final state (completed, canceled,
//    failed) and nothing is left running;
//  - a completed file is byte-identical to what was sent;
//  - a sender completes only if its receiver did (AXDP and YAPP both wait
//    for the receiver's final acknowledgment);
//  - with no action and a mild channel, the transfer completes;
//  - a cancel or decline reaches both ends;
//  - chat lines arrive complete and in order while the link holds.
//
//  The report goes to the test host's temporary directory,
//  AXTermStress/fullstack-transfers.txt.
//

import XCTest
@testable import AXTerm

@MainActor
final class FullStackTransferFuzzTests: XCTestCase {

    private enum Kind: String { case axdp, yapp, chat }
    private enum Action: String { case none, pauseResume, cancelSender, cancelReceiver, decline, outage, disconnect }

    private static func isFinal(_ status: BulkTransferStatus?) -> Bool {
        switch status {
        case .completed, .cancelled, .failed: return true
        default: return false
        }
    }

    func testRandomTransfersAndChatOverAnImpairedLink() async throws {
        var report: [String] = []
        var problems: [String] = []
        for seed in FullStackFuzz.seeds(normal: 3) {
            let (lines, found) = await runScenario(seed: seed)
            report += lines
            problems += found
        }
        StressReport.write(report + ["", "Problems: \(problems.count)"] + problems, name: "fullstack-transfers")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    // MARK: One scenario

    private func runScenario(seed: UInt64) async -> (report: [String], problems: [String]) {
        var pick = FuzzPicker(seed: seed)
        var impairment = FuzzKISSLink.Impairment()
        impairment.loss = pick.pick([0, 0, 0.02, 0.05, 0.1])
        impairment.duplicate = pick.pick([0, 0, 0.02, 0.05])
        impairment.jitter = pick.pick([0, 0.02, 0.08])
        impairment.chunked = pick.chance(0.5)
        let mild = impairment.loss <= 0.05

        let a = FuzzStation(callsign: "K0AAA-1", seed: seed &* 2)
        let b = FuzzStation(callsign: "K0BBB-2", seed: seed &* 2 &+ 1)
        defer { a.tearDown(); b.tearDown() }
        a.link.impairment = impairment
        b.link.impairment = impairment
        a.connectLink(to: b)
        b.connectLink(to: a)

        var report = ["seed \(seed): \(impairment)"]
        var problems: [String] = []
        var opStarted = Date()
        func problem(_ text: String) {
            problems.append("seed \(seed): \(text)")
            if FullStackFuzz.tracing {
                problems += FullStackFuzz.trace(a, b, since: opStarted)
            }
        }

        guard await connect(a, b) else {
            problem("the link never came up (\(impairment))")
            return (report, problems)
        }

        let operations = pick.int(2...5)
        for index in 0..<operations {
            opStarted = Date()
            if a.session == nil || b.session == nil {
                guard await connect(a, b) else {
                    problem("op \(index): the link did not come back")
                    break
                }
            }
            // Chat on a link still closing reopens it without connect()
            // above, and the reopened link has forgotten AXDP. Discovery
            // would relearn it; stand in for that before every operation.
            a.coordinator.markImplicitlyConfirmedAXDP(for: b.callsign)
            b.coordinator.markImplicitlyConfirmedAXDP(for: a.callsign)
            // A duplicated UA or SABM makes a station set the link up again
            // (AX.25 2.2 SDL, error C), and the reset discards what was
            // queued. That is the protocol working, so on a channel that
            // duplicates, an operation the link was reset under is excused
            // from finishing; its results must still be consistent.
            let sabmsBefore = a.link.sabmsSent + b.link.sabmsSent
            func resetUnder() -> Bool {
                impairment.duplicate > 0 && a.link.sabmsSent + b.link.sabmsSent > sabmsBefore
            }
            // A YAPP receive still waiting for its header owns the byte
            // stream; noted so a lost offer or chat can be traced to it.
            let waitingYAPP = [(a, "A"), (b, "B")].filter { !$0.0.coordinator.yappAwaitingHeader.isEmpty }.map(\.1)
            if !waitingYAPP.isEmpty {
                report.append("  (op \(index) starts with a YAPP receive waiting for its header on \(waitingYAPP.joined(separator: ", ")))")
            }
            let kind = pick.pick([Kind.axdp, .axdp, .yapp, .yapp, .chat])
            let forward = pick.chance(0.6)
            let (sender, receiver) = forward ? (a, b) : (b, a)
            let direction = forward ? "A>B" : "B>A"

            if kind == .chat {
                let lines = (0..<pick.int(1...8)).map { "L\(seed)-\(index)-\($0) \(String(repeating: "x", count: pick.int(0...150)))\r" }
                for line in lines {
                    let frames = sender.coordinator.sessionManager.sendData(
                        Data(line.utf8), to: receiver.address, radio: sender.coordinator.primaryRadioID)
                    frames.forEach { sender.coordinator.sendFrame($0) }
                }
                let wanted = Data(lines.joined().utf8)
                let arrived = await FullStackFuzz.wait(40) { receiver.terminalText.range(of: wanted) != nil }
                report.append("  op \(index) chat \(direction) \(lines.count) lines: \(arrived ? "arrived in order" : "NOT ARRIVED")\(resetUnder() ? " (link reset)" : "")")
                if !arrived, sender.session != nil, receiver.session != nil, !resetUnder() {
                    problem("op \(index): chat lines \(direction) did not arrive complete and in order on a live link")
                }
                continue
            }

            let size = pick.pick([0, 1, 127, 128, 129, 600, 2000, 5000, 9000])
            let data: Data = pick.chance(0.3)
                ? Data(String(repeating: "CQ CQ de K0AAA \(index) ", count: size / 16 + 1).utf8.prefix(size))
                : pick.bytes(size)
            let name = "F\(seed)X\(index).BIN"
            let compression: TransferCompressionSettings = kind == .axdp
                ? pick.pick([.disabled, .withAlgorithm(.lz4), .withAlgorithm(.deflate), .useGlobal])
                : .disabled
            let action = pick.pick([Action.none, .none, .none, .none, .pauseResume, .cancelSender,
                                    .cancelReceiver, .decline, .outage, .disconnect])
            let type: TransferProtocolType = kind == .axdp ? .axdp : .yapp

            if let error = sender.coordinator.startTransfer(to: receiver.callsign, fileName: name, data: data,
                                                            transferProtocol: type, compressionSettings: compression) {
                report.append("  op \(index) \(kind.rawValue) \(direction) \(size) B: refused to start (\(error))")
                problem("op \(index): \(kind.rawValue) refused to start on a live link: \(error)")
                continue
            }

            let offered = await FullStackFuzz.wait(30) {
                receiver.coordinator.pendingIncomingTransfers.contains { $0.fileName == name }
            }
            if offered, let offer = receiver.coordinator.pendingIncomingTransfers.first(where: { $0.fileName == name }) {
                if action == .decline {
                    receiver.coordinator.declineIncomingTransfer(offer.id)
                } else {
                    receiver.coordinator.acceptIncomingTransfer(offer.id)
                }
            }

            var actionTaken = action
            // A cancel sent once every byte had left the sender can cross
            // the receiver finishing (YAPP delivers on EF, AXDP on the last
            // chunk), so the other side completing is then allowed.
            var canceledLate = false
            if offered, action != .none, action != .decline {
                // Somewhere in the middle, if it gets that far.
                let target = max(1, data.count / pick.int(2...5))
                let underway = await FullStackFuzz.wait(30) {
                    (receiver.transfer(named: name)?.bytesSent ?? 0) >= target
                        || Self.isFinal(receiver.transfer(named: name)?.status)
                }
                if underway, !Self.isFinal(sender.transfer(named: name)?.status),
                   !Self.isFinal(receiver.transfer(named: name)?.status) {
                    switch action {
                    case .pauseResume:
                        if let id = sender.transfer(named: name)?.id {
                            sender.coordinator.pauseTransfer(id)
                            try? await Task.sleep(nanoseconds: UInt64(pick.uniform(0.3, 2) * 1e9))
                            sender.coordinator.resumeTransfer(id)
                        }
                    case .cancelSender, .cancelReceiver:
                        canceledLate = (sender.transfer(named: name)?.bytesSent ?? 0) >= data.count
                            || sender.transfer(named: name)?.status == .awaitingCompletion
                        let side = action == .cancelSender ? sender : receiver
                        if let id = side.transfer(named: name)?.id { side.coordinator.cancelTransfer(id) }
                    case .outage:
                        a.link.silenced = true
                        b.link.silenced = true
                        try? await Task.sleep(nanoseconds: UInt64(pick.uniform(1, 4) * 1e9))
                        a.link.silenced = false
                        b.link.silenced = false
                    case .disconnect:
                        if let session = sender.session,
                           let disc = sender.coordinator.sessionManager.disconnect(session: session) {
                            sender.coordinator.sendFrame(disc)
                        }
                    case .none, .decline:
                        break
                    }
                } else {
                    actionTaken = .none   // finished before the action point
                }
            }

            let settled = await FullStackFuzz.wait(120) {
                Self.isFinal(sender.transfer(named: name)?.status)
                    && (Self.isFinal(receiver.transfer(named: name)?.status) || receiver.transfer(named: name) == nil)
            }
            let s = sender.transfer(named: name)?.status
            let r = receiver.transfer(named: name)?.status
            if !offered { actionTaken = .none }
            let reset = resetUnder()
            report.append("  op \(index) \(kind.rawValue) \(direction) \(data.count) B \(actionTaken.rawValue)\(offered ? "" : " (no offer)")\(reset ? " (link reset)" : ""): "
                          + "sender \(s.map { "\($0)" } ?? "none"), receiver \(r.map { "\($0)" } ?? "none")")

            if !offered, sender.session != nil, receiver.session != nil, mild, !reset {
                problem("op \(index) \(kind.rawValue): the offer never reached the receiver on a live link (\(impairment)): sender \(String(describing: s))")
            }
            // A YAPP cancel keeps the session claimed until the other side's
            // CA arrives (up to 10 s), so the CA is not typed into the
            // terminal; the row says canceled before that. Starting the next
            // transfer in that gap is refused as busy, rightly, so wait it
            // out. Still held after 15 s is a leak.
            if kind == .yapp {
                let released = await FullStackFuzz.wait(15) {
                    a.coordinator.yappTransfers.isEmpty && b.coordinator.yappTransfers.isEmpty
                }
                if !released, settled { problem("op \(index) yapp: a runner still holds the session 15 s after the transfer ended") }
            }
            if !settled {
                problem("op \(index) \(kind.rawValue) \(actionTaken.rawValue): not final after 120 s: sender \(String(describing: s)), receiver \(String(describing: r))")
                continue
            }
            if r == .completed, receiver.savedData(receiver.transfer(named: name)) != data {
                problem("op \(index) \(kind.rawValue): the receiver completed with different bytes (\(data.count) sent)")
            }
            if s == .completed, r != .completed {
                problem("op \(index) \(kind.rawValue): the sender completed but the receiver says \(String(describing: r))")
            }
            switch actionTaken {
            case .none, .pauseResume:
                if mild, offered, !reset, s != .completed || r != .completed {
                    problem("op \(index) \(kind.rawValue) \(actionTaken.rawValue): did not complete on a mild channel (\(impairment)): sender \(String(describing: s)), receiver \(String(describing: r))")
                }
            case .cancelSender, .cancelReceiver:
                let canceler = actionTaken == .cancelSender ? s : r
                // A late cancel may find the file already acknowledged and
                // let the transfer finish.
                if canceler != .cancelled, !(canceledLate && canceler == .completed) {
                    problem("op \(index) \(kind.rawValue): the side that canceled says \(String(describing: canceler))")
                }
                let other = actionTaken == .cancelSender ? r : s
                if other == .completed, !canceledLate {
                    problem("op \(index) \(kind.rawValue): canceled, but the other side completed")
                }
            case .decline:
                if r != nil, r != .cancelled { problem("op \(index) \(kind.rawValue): declined, receiver says \(String(describing: r))") }
                if s == .completed { problem("op \(index) \(kind.rawValue): declined, but the sender completed") }
            case .disconnect, .outage:
                break
            }
        }

        // Nothing left running or holding the session.
        let quiet = await FullStackFuzz.wait(20) {
            a.coordinator.yappTransfers.isEmpty && b.coordinator.yappTransfers.isEmpty
        }
        if !quiet { problem("YAPP transfers still held after the run") }
        for (station, label) in [(a, "A"), (b, "B")] {
            for transfer in station.coordinator.transfers where !Self.isFinal(transfer.status) {
                problem("\(label) still has \(transfer.fileName) \(transfer.status)")
            }
        }
        return (report, problems)
    }

    private func connect(_ a: FuzzStation, _ b: FuzzStation) async -> Bool {
        for _ in 0..<3 {
            if let sabm = a.coordinator.sessionManager.connect(to: b.address, path: DigiPath(),
                                                               radio: a.coordinator.primaryRadioID) {
                a.coordinator.sendFrame(sabm)
            }
            if await FullStackFuzz.wait(30, { a.session != nil && b.session != nil }) {
                // A disconnect forgets what the peer can do (rediscovered on
                // each connect); stand in for that discovery here.
                a.coordinator.markImplicitlyConfirmedAXDP(for: b.callsign)
                b.coordinator.markImplicitlyConfirmedAXDP(for: a.callsign)
                return true
            }
        }
        return false
    }
}
