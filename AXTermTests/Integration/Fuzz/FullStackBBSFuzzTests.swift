//
//  FullStackBBSFuzzTests.swift
//  AXTermTests
//
//  A caller using the mailbox over an impaired link. Station B runs the
//  mailbox (BBSService) on its own SSID; station A connects to it and types
//  random sessions: messages sent line by line or typed ahead in one go,
//  messages abandoned by a disconnect, lists, reads, kills, garbage, bursts
//  of commands, and outages in the middle. Production code from KISS
//  framing up at both ends; see FullStackFuzzSupport.
//
//  What must hold:
//  - "Message N stored." is said exactly when the store holds message N, as
//    sent (from, to, subject, body), once;
//  - a message the caller never finished is never stored;
//  - reading a message gives back every line of its body;
//  - a kill only marks the message killed;
//  - on a live link that was not reset, every command is answered with a
//    prompt;
//  - when the caller hangs up, the mailbox closes the call.
//
//  Report: AXTermStress/fullstack-bbs.txt in the test host's temporary
//  directory.
//

import XCTest
import GRDB
@testable import AXTerm

@MainActor
final class FullStackBBSFuzzTests: XCTestCase {

    private enum Op: String { case send, typeAhead, abandon, list, read, kill, garbage, burst, outage }

    private let mailboxCall = "K0BBB-4"

    func testRandomMailboxSessionsOverAnImpairedLink() async throws {
        var report: [String] = []
        var problems: [String] = []
        for seed in FullStackFuzz.seeds(normal: 3) {
            let (lines, found) = try await runScenario(seed: seed)
            report += lines
            problems += found
        }
        StressReport.write(report + ["", "Problems: \(problems.count)"] + problems, name: "fullstack-bbs")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    // MARK: One scenario

    private func runScenario(seed: UInt64) async throws -> (report: [String], problems: [String]) {
        var pick = FuzzPicker(seed: seed ^ 0xBB5)
        var impairment = FuzzKISSLink.Impairment()
        impairment.loss = pick.pick([0, 0, 0.02, 0.05, 0.1])
        impairment.duplicate = pick.pick([0, 0, 0.02, 0.05])
        impairment.jitter = pick.pick([0, 0.02, 0.08])
        impairment.chunked = pick.chance(0.5)
        let mild = impairment.loss <= 0.05

        let a = FuzzStation(callsign: "K0AAA-1", seed: seed &* 2)
        let b = FuzzStation(callsign: "K0BBB-2", seed: seed &* 2 &+ 1)
        a.link.impairment = impairment
        b.link.impairment = impairment
        a.connectLink(to: b)
        b.connectLink(to: a)

        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let store = SQLiteBBSMessageStore(dbQueue: queue)
        let settings = BBSSettings(defaults: TestDefaults.make("fuzz-bbs-\(seed)"))
        settings.onAir = true
        settings.callsign = mailboxCall
        let service = BBSService(
            store: store, settings: settings, coordinator: b.coordinator,
            sendFrames: { [weak coordinator = b.coordinator] frames in frames.forEach { coordinator?.sendFrame($0) } },
            stationCallsign: { "K0BBB" },
            isWinlinkP2PArmed: { false },
            winlinkP2PCallsign: { "" },
            library: BBSFileLibrary(store: store),
            linkBytesPerSecond: { 1_000_000 })
        service.attach()
        defer {
            service.shutdown(reason: "test over")
            service.detach()
            a.tearDown()
            b.tearDown()
        }
        let mailbox = CallsignNormalizer.toAddress(mailboxCall)

        var report = ["seed \(seed): \(impairment)"]
        var problems: [String] = []
        var opStarted = Date()
        var sabmsBefore = 0
        func resetUnder() -> Bool {
            impairment.duplicate > 0 && a.link.sabmsSent + b.link.sabmsSent > sabmsBefore
        }
        func problem(_ text: String) {
            problems.append("seed \(seed): \(text)")
            if FullStackFuzz.tracing { problems += FullStackFuzz.trace(a, b, since: opStarted) }
        }

        // What the caller has seen since `mark`.
        var mark = 0
        func since() -> String { String(decoding: a.terminalText.dropFirst(mark), as: UTF8.self) }
        func type(_ text: String) {
            mark = a.terminalText.count
            for frame in a.coordinator.sessionManager.sendData(Data(text.utf8), to: mailbox,
                                                               radio: a.coordinator.primaryRadioID) {
                a.coordinator.sendFrame(frame)
            }
        }
        func linkUp() -> Bool {
            a.coordinator.connectedSessions.contains { $0.remoteAddress == mailbox }
        }
        func prompted(_ text: String) -> Bool { text.hasSuffix(">\r") }

        /// Calls the mailbox and gets past the greeting (and, the first
        /// time, the interview).
        func call() async -> Bool {
            for _ in 0..<3 {
                mark = a.terminalText.count
                if let sabm = a.coordinator.sessionManager.connect(to: mailbox, path: DigiPath(),
                                                                   radio: a.coordinator.primaryRadioID) {
                    a.coordinator.sendFrame(sabm)
                }
                guard await FullStackFuzz.wait(30, { linkUp() }) else { continue }
                guard await FullStackFuzz.wait(30, { prompted(since()) || since().contains("Your name:") }) else { return false }
                if since().contains("Your name:") {
                    type("Fuzz Caller\r")
                    // Each question ends its line with a colon; Return skips it.
                    for _ in 0..<8 {
                        guard await FullStackFuzz.wait(30, { prompted(since()) || since().hasSuffix(":\r") }) else { return false }
                        if prompted(since()) { break }
                        type("\r")
                    }
                }
                return await FullStackFuzz.wait(30) { prompted(since()) }
            }
            return false
        }
        func hangUp() async {
            if let session = a.coordinator.connectedSessions.first(where: { $0.remoteAddress == mailbox }),
               let disc = a.coordinator.sessionManager.disconnect(session: session) {
                a.coordinator.sendFrame(disc)
            }
            _ = await FullStackFuzz.wait(30) { service.live == nil && !linkUp() }
        }

        guard await call() else {
            problem("could not reach the mailbox's prompt (\(impairment))")
            return (report, problems)
        }

        // Messages the caller saw stored, by subject, and every subject
        // that was ever begun.
        var stored: [String: (id: Int64, to: String, body: [String])] = [:]
        var begun: Set<String> = []
        var killed: Set<Int64> = []

        let operations = pick.int(4...10)
        for index in 0..<operations {
            if !linkUp() || service.live == nil {
                guard await call() else { problem("op \(index): could not call the mailbox back"); break }
            }
            opStarted = Date()
            sabmsBefore = a.link.sabmsSent + b.link.sabmsSent
            let op = pick.pick([Op.send, .send, .typeAhead, .abandon, .list, .read, .kill, .garbage, .burst, .outage])
            var line = "  op \(index) \(op.rawValue)"

            switch op {
            case .send, .typeAhead, .outage:
                let to = pick.pick(["K0BBB", "ALL", "W1AW", "K0AAA", "N0CALL @ N0BBS"])
                let subject = "Fuzz \(seed)-\(index) \(pick.pick(["net", "test", "photo", ""]))"
                    .trimmingCharacters(in: .whitespaces)
                let body = (0..<pick.int(0...8)).map { _ in
                    pick.chance(0.15) ? "" : (0..<pick.int(1...30))
                        .map { _ in pick.pick(["CQ", "de", "K0AAA", "73", "QSL?", "net", "at", "1900", "local", "x"]) }
                        .joined(separator: " ")
                }
                begun.insert(subject)
                let script = ["S \(to)", subject] + body + ["/EX"]
                var answered = true
                if op == .typeAhead {
                    type(script.map { $0 + "\r" }.joined())
                } else {
                    for (i, text) in script.enumerated() {
                        type(text + "\r")
                        if op == .outage, i == script.count / 2 {
                            a.link.silenced = true
                            b.link.silenced = true
                            try? await Task.sleep(nanoseconds: UInt64(pick.uniform(1, 4) * 1e9))
                            a.link.silenced = false
                            b.link.silenced = false
                        }
                        // The mailbox answers the command and the subject;
                        // body lines get nothing back.
                        if i < 2 {
                            let wanted = i == 0 ? "Subj:" : "end with /EX"
                            if !(await FullStackFuzz.wait(40) { since().contains(wanted) }) { answered = false; break }
                        }
                    }
                }
                if answered {
                    answered = await FullStackFuzz.wait(40) { prompted(since()) && since().contains("stored") }
                }
                let reply = since()
                if let range = reply.range(of: #"Message (\d+) stored\."#, options: .regularExpression),
                   let id = Int64(reply[range].split(separator: " ")[1]) {
                    stored[subject] = (id, to, body)
                    line += " #\(id) to \(to), \(body.count) lines"
                } else {
                    line += " not stored"
                    if mild, linkUp(), !resetUnder() {
                        problem("op \(index) \(op.rawValue): no \"stored\" on a live link (\(impairment)); the caller saw \(reply.suffix(120).debugDescription)")
                    }
                }

            case .abandon:
                let subject = "Abandoned \(seed)-\(index)"
                begun.insert(subject)
                type("S K0BBB\r\(subject)\r")
                _ = await FullStackFuzz.wait(40) { since().contains("end with /EX") }
                type((0..<pick.int(0...3)).map { "line \($0)\r" }.joined())
                try? await Task.sleep(nanoseconds: UInt64(pick.uniform(0, 1.5) * 1e9))
                await hangUp()
                line += " (hung up mid-message)"

            case .list:
                type(pick.pick(["L", "LM", "LB", "LL 5"]) + "\r")
                if !(await FullStackFuzz.wait(40) { prompted(since()) }), mild, linkUp(), !resetUnder() {
                    problem("op \(index) list: no prompt on a live link (\(impairment))")
                }

            case .read:
                let live = stored.filter { !killed.contains($0.value.id) }.sorted { $0.value.id < $1.value.id }
                guard let (subject, message) = pick.element(live) else {
                    type("R 999\r")
                    _ = await FullStackFuzz.wait(40) { prompted(since()) }
                    line += " (nothing to read)"
                    break
                }
                type("R \(message.id)\r")
                let ok = await FullStackFuzz.wait(40) { prompted(since()) }
                let text = since()
                line += " #\(message.id)"
                if ok, !text.contains("Subj: \(subject)") || message.body.contains(where: { !text.contains($0 + "\r") }) {
                    problem("op \(index) read #\(message.id): the body did not come back whole: \(text.suffix(200).debugDescription)")
                } else if !ok, mild, linkUp(), !resetUnder() {
                    problem("op \(index) read: no prompt on a live link (\(impairment))")
                }

            case .kill:
                let mine = stored.filter { !killed.contains($0.value.id) }.sorted { $0.value.id < $1.value.id }
                guard let (_, message) = pick.element(mine) else {
                    line += " (nothing to kill)"
                    break
                }
                type("K \(message.id)\r")
                let ok = await FullStackFuzz.wait(40) { prompted(since()) }
                if since().contains("Message \(message.id) killed.") {
                    killed.insert(message.id)
                    line += " #\(message.id)"
                } else if ok || (mild && linkUp() && !resetUnder()) {
                    problem("op \(index) kill #\(message.id): not killed: \(since().suffix(120).debugDescription)")
                }

            case .garbage:
                // No letters, so it cannot be a command; no CR, LF or ^Z.
                let pool = Array(0x00...0x1F).filter { ![0x0A, 0x0D, 0x1A].contains($0) }
                    + Array(0x21...0x2F) + Array(0x7F...0xFF)
                let bytes = (0..<pick.int(1...300)).map { _ in UInt8(pick.pick(pool)) }
                mark = a.terminalText.count
                for frame in a.coordinator.sessionManager.sendData(Data(bytes) + Data([0x0D]), to: mailbox,
                                                                   radio: a.coordinator.primaryRadioID) {
                    a.coordinator.sendFrame(frame)
                }
                if !(await FullStackFuzz.wait(40) { prompted(since()) }), mild, linkUp(), !resetUnder() {
                    problem("op \(index) garbage (\(bytes.count) bytes): no prompt on a live link (\(impairment))")
                }

            case .burst:
                let commands = (0..<pick.int(2...5)).map { _ in pick.pick(["H", "L", "V", "I", "J"]) }
                type(commands.map { $0 + "\r" }.joined())
                let all = await FullStackFuzz.wait(60) { since().components(separatedBy: "\r>\r").count - 1 >= commands.count }
                line += " \(commands.joined(separator: ","))"
                if !all, mild, linkUp(), !resetUnder() {
                    problem("op \(index) burst of \(commands.count): \(since().components(separatedBy: "\r>\r").count - 1) prompts on a live link (\(impairment))")
                }
            }
            report.append(line + (resetUnder() ? " (link reset)" : ""))
        }

        await hangUp()
        if service.live != nil { problem("the mailbox still holds a call after the caller hung up") }

        // The store against what the caller was told.
        let messages = try store.allMessages()
        for (subject, expected) in stored {
            let matches = messages.filter { $0.subject == subject }
            guard matches.count == 1, let message = matches.first else {
                problem("\"\(subject)\" was reported stored as #\(expected.id) but the store has \(matches.count)")
                continue
            }
            if message.id != expected.id { problem("\"\(subject)\" was reported as #\(expected.id), stored as #\(message.id)") }
            if message.from != "K0AAA-1" { problem("#\(message.id) is from \(message.from)") }
            if message.to != expected.to.replacingOccurrences(of: " ", with: "").split(separator: "@").first.map(String.init) {
                problem("#\(message.id) is to \(message.to), sent to \(expected.to)")
            }
            if message.body != expected.body.joined(separator: "\n") { problem("#\(message.id) body differs from what was sent") }
            if killed.contains(message.id) != (message.killedAt != nil) {
                problem("#\(message.id) killed \(killed.contains(message.id)) but the store says \(message.killedAt != nil)")
            }
        }
        for message in messages where stored[message.subject] == nil {
            problem("#\(message.id) \"\(message.subject)\" is stored but the caller was never told"
                    + (begun.contains(message.subject) ? "" : " (and never sent it)"))
        }
        report.append("  stored \(stored.count), killed \(killed.count), in store \(messages.count)")
        return (report, problems)
    }
}
