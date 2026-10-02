//
//  FullStackNodeFuzzTests.swift
//  AXTermTests
//
//  A caller using the NET/ROM node shell over plain AX.25. Station B runs
//  the node with inbound callers accepted; its alias answers connects the
//  way a KA-node neighbor reaches it. Station A connects to the alias and
//  types random sessions: every shell command, garbage, bursts of commands,
//  a connect onward to a station that is not there, BYE, and hang-ups and
//  outages in the middle. Production code from KISS framing up; see
//  FullStackFuzzSupport.
//
//  What must hold:
//  - on a live link that was not reset, every command comes back with the
//    node prompt, and a failed connect onward returns the caller to it;
//  - BYE ends the link from the node's side;
//  - nothing the caller types reaches B's terminal;
//  - when the caller is gone, the node holds no caller for it.
//
//  Report: AXTermStress/fullstack-node.txt in the test host's temporary
//  directory.
//

import XCTest
@testable import AXTerm

@MainActor
final class FullStackNodeFuzzTests: XCTestCase {

    private enum Op: String { case command, garbage, burst, connectOnward, bye, hangUp, outage }

    private let alias = "BBBNOD"

    func testRandomNodeSessionsOverAnImpairedLink() async throws {
        var report: [String] = []
        var problems: [String] = []
        for seed in FullStackFuzz.seeds(normal: 3) {
            let (lines, found) = await runScenario(seed: seed)
            report += lines
            problems += found
        }
        StressReport.write(report + ["", "Problems: \(problems.count)"] + problems, name: "fullstack-node")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    private func runScenario(seed: UInt64) async -> (report: [String], problems: [String]) {
        var pick = FuzzPicker(seed: seed ^ 0x40DE)
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
        b.settings.netRomAcceptInbound = true
        b.settings.netRomNodeAlias = alias
        b.coordinator.applyNetRomNodeSettings(b.settings)
        // ContentView supplies the identity in the app (wireNetRomNodeHost).
        b.coordinator.netRomNodeHost.identityProvider = { [alias] in (alias, "K0BBB-2", "AXTerm") }
        let node = CallsignNormalizer.toAddress(alias)

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

        var mark = 0
        func since() -> String { String(decoding: a.terminalText.dropFirst(mark), as: UTF8.self) }
        func send(_ data: Data) {
            mark = a.terminalText.count
            for frame in a.coordinator.sessionManager.sendData(data, to: node, radio: a.coordinator.primaryRadioID) {
                a.coordinator.sendFrame(frame)
            }
        }
        func type(_ text: String) { send(Data(text.utf8)) }
        func prompted() -> Bool { since().hasSuffix("} ") }
        func linkUp() -> Bool { a.coordinator.connectedSessions.contains { $0.remoteAddress == node } }
        func nodeLinkGone() -> Bool { !b.coordinator.connectedSessions.contains { $0.remoteAddress == a.address } }
        func call() async -> Bool {
            for _ in 0..<3 {
                mark = a.terminalText.count
                if let sabm = a.coordinator.sessionManager.connect(to: node, path: DigiPath(),
                                                                   radio: a.coordinator.primaryRadioID) {
                    a.coordinator.sendFrame(sabm)
                }
                guard await FullStackFuzz.wait(30, { linkUp() }) else { continue }
                return await FullStackFuzz.wait(30) { prompted() }
            }
            return false
        }
        func hangUp() async {
            if let session = a.coordinator.connectedSessions.first(where: { $0.remoteAddress == node }),
               let disc = a.coordinator.sessionManager.disconnect(session: session) {
                a.coordinator.sendFrame(disc)
            }
            _ = await FullStackFuzz.wait(30) { !linkUp() && nodeLinkGone() }
        }

        guard await call() else {
            problem("could not reach the node prompt (\(impairment))")
            return (report, problems)
        }

        for index in 0..<pick.int(4...10) {
            if !linkUp() {
                guard await call() else { problem("op \(index): could not call the node back"); break }
            }
            opStarted = Date()
            sabmsBefore = a.link.sabmsSent + b.link.sabmsSent
            let op = pick.pick([Op.command, .command, .command, .garbage, .burst, .connectOnward, .bye, .hangUp, .outage])
            var line = "  op \(index) \(op.rawValue)"
            let excused = { !mild || !linkUp() || resetUnder() }

            switch op {
            case .command, .outage:
                let command = pick.pick(["H", "?", "INFO", "NODES", "N", "ROUTES", "MH", "J", "BBS", "C", "xyzzy", "", "  nodes  "])
                line += " \(command.debugDescription)"
                type(command + pick.pick(["\r", "\r\n", "\n"]))
                if op == .outage {
                    a.link.silenced = true
                    b.link.silenced = true
                    try? await Task.sleep(nanoseconds: UInt64(pick.uniform(1, 4) * 1e9))
                    a.link.silenced = false
                    b.link.silenced = false
                }
                if !(await FullStackFuzz.wait(40) { prompted() }), !excused() {
                    problem("op \(index) \(command.debugDescription): no prompt on a live link (\(impairment)): \(since().suffix(120).debugDescription)")
                }

            case .garbage:
                let pool = Array(0x00...0x1F).filter { ![0x0A, 0x0D].contains($0) } + Array(0x21...0x2F) + Array(0x7F...0xFF)
                let bytes = (0..<pick.int(1...300)).map { _ in UInt8(pick.pick(pool)) }
                send(Data(bytes) + Data([0x0D]))
                line += " \(bytes.count) bytes"
                if !(await FullStackFuzz.wait(40) { prompted() }), !excused() {
                    problem("op \(index) garbage: no prompt on a live link (\(impairment))")
                }

            case .burst:
                let commands = (0..<pick.int(2...5)).map { _ in pick.pick(["H", "I", "N", "R", "MH"]) }
                type(commands.map { $0 + "\r" }.joined())
                line += " \(commands.joined(separator: ","))"
                let all = await FullStackFuzz.wait(60) { since().components(separatedBy: "} ").count - 1 >= commands.count }
                if !all, !excused() {
                    problem("op \(index) burst of \(commands.count): \(since().components(separatedBy: "} ").count - 1) prompts on a live link (\(impairment))")
                }

            case .connectOnward:
                // Nobody answers as W9XYZ; the node's own L2 gives up and
                // the caller comes back to the prompt.
                type("C W9XYZ\r")
                let back = await FullStackFuzz.wait(90) { since().contains("Trying") && prompted() }
                if !back, !excused() {
                    problem("op \(index) C W9XYZ: the caller never came back to the prompt: \(since().suffix(160).debugDescription)")
                }

            case .bye:
                type(pick.pick(["B", "BYE", "Q"]) + "\r")
                let ended = await FullStackFuzz.wait(40) { !linkUp() && nodeLinkGone() }
                if !ended, !excused() { problem("op \(index) BYE: the node did not end the link") }

            case .hangUp:
                type(pick.pick(["NODES\r", "ROUTES\r", "H\r"]))
                try? await Task.sleep(nanoseconds: UInt64(pick.uniform(0, 1) * 1e9))
                await hangUp()
            }
            report.append(line + (resetUnder() ? " (link reset)" : ""))
        }

        await hangUp()
        let released = await FullStackFuzz.wait(30) { b.coordinator.netRomNodeHost.activeCallerCount == 0 }
        if !released {
            problem("the node still holds \(b.coordinator.netRomNodeHost.activeCallerCount) caller(s) after the caller left")
        }
        if !b.terminalText.isEmpty {
            problem("\(b.terminalText.count) bytes the caller typed reached B's terminal")
        }
        return (report, problems)
    }
}
