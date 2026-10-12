//
//  SecurityStationTests.swift
//  AXTermTests
//
//  Security suite (Docs/SecurityTesting.md), part 3: the station. The
//  rules that keep remote control lawful and recoverable (97.213: a direct
//  control link on an auxiliary-station frequency, and a fail-safe within
//  3 minutes), names a stranger sends that become files on the operator's
//  disk, and what a caller can make the station hold.
//

import XCTest
@testable import AXTerm

// MARK: - The control link (97.201, 97.213)

final class SecurityControlLinkTests: XCTestCase {

    private func allowed(_ mhz: Double) -> Bool {
        TelecommandLink.refusal(frequencyHz: Int((mhz * 1_000_000).rounded()), digipeated: false) == nil
    }

    /// SEC-24. The excluded segments are refused at both edges, and the
    /// frequencies just outside them are allowed.
    func testTheExcludedSegmentsHoldAtTheirEdges() {
        for mhz in [144.000, 144.250, 144.500, 145.800, 145.900, 146.000, 219.000, 220.000, 222.000, 222.150,
                    431.000, 433.000, 435.000, 438.000] {
            XCTAssertFalse(allowed(mhz), "\(mhz)")
        }
        for mhz in [144.501, 145.650, 145.799, 146.001, 147.000, 223.500, 430.000, 433.001, 446.000, 1294.000] {
            XCTAssertTrue(allowed(mhz), "\(mhz)")
        }
    }

    /// SEC-24. Below 2 m is never a control link: HF and 6 m.
    func testBelowTwoMetersIsRefused() {
        for mhz in [1.8, 3.5, 7.074, 14.105, 28.12, 50.62, 143.999] { XCTAssertFalse(allowed(mhz), "\(mhz)") }
    }

    /// SEC-25. Unknown frequency, a digipeater or a NET/ROM circuit: refused.
    func testAnUncertainOrRelayedLinkIsRefused() {
        XCTAssertNotNil(TelecommandLink.refusal(frequencyHz: nil, digipeated: false))
        XCTAssertNotNil(TelecommandLink.refusal(frequencyHz: 145_650_000, digipeated: true))
    }
}

// MARK: - The fail-safe (97.213(b))

@MainActor
final class SecurityFailSafeTests: XCTestCase {

    private final class Rig: RigctlTransport, @unchecked Sendable {
        var sent: [String] = []
        var failsRestore = false
        func exchange(host: String, port: Int, line: String) async throws -> [String] {
            sent.append(line)
            if line.hasPrefix("l ") { return ["0.200000"] }
            if line == "f" { return ["146520000"] }
            if failsRestore && (line.hasSuffix("0.200000") || line.hasSuffix("146520000")) { return ["RPRT -9"] }
            return ["RPRT 0"]
        }
    }

    private final class NoScripts: ScriptRunning, @unchecked Sendable {
        func run(script: String, arguments: [String]) async throws -> [String] { [] }
    }

    private let rig = Rig()
    private let direct = RemoteControlService.LinkFacts(radio: .primary, digipeated: false, relayed: false)

    private func service(_ label: String, silence: Duration = .seconds(150)) -> RemoteControlService {
        let defaults = TestDefaults.make(label)
        let service = RemoteControlService(settings: BBSSettings(defaults: defaults), defaults: defaults)
        service.runner = OwnerControlRunner(rigctl: rig, scripts: NoScripts())
        service.linkFrequencyHz = { _ in 145_650_000 }
        service.silenceLimit = silence
        return service
    }

    private func power(_ radio: String = "705", port: Int = 4533) -> OwnerControlCommand {
        OwnerControlCommand(name: "PWR \(radio)", help: "", argument: .number(min: 0.5, max: 10),
                            action: .rigctl(host: "localhost", port: port, set: "L RFPOWER {arg}", read: "l RFPOWER"),
                            changesTransmission: true, scale: 10, unit: "W")
    }

    private func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    /// SEC-26. The silence limit leaves room inside 97.213(b)'s 3 minutes.
    func testTheSilenceLimitIsInsideThreeMinutes() {
        XCTAssertLessThan(RemoteControlService(settings: BBSSettings(defaults: TestDefaults.make("fs-limit")),
                                               defaults: TestDefaults.make("fs-limit")).silenceLimit, .seconds(180))
    }

    /// SEC-27. Several changes go back newest first, so each restore sees
    /// the state it read.
    func testChangesGoBackNewestFirst() async {
        let sut = service("fs-order")
        sut.run(power("705"), argument: "5", link: "L", facts: direct, caller: "K0EPI-3", door: "node",
                write: { _ in }, prompt: nil)
        await settle()
        sut.run(power("710", port: 4532), argument: "8", link: "L", facts: direct, caller: "K0EPI-3", door: "node",
                write: { _ in }, prompt: nil)
        await settle()
        rig.sent.removeAll()
        sut.linkEnded("L", failed: true)
        await settle()
        XCTAssertEqual(rig.sent, ["L RFPOWER 0.200000", "L RFPOWER 0.200000"])
    }

    /// SEC-28. A restore that fails is logged as failed, not as done.
    func testAFailedRestoreIsLoggedAsFailed() async {
        let sut = service("fs-failed")
        rig.failsRestore = true
        sut.run(power(), argument: "5", link: "L", facts: direct, caller: "K0EPI-3", door: "node", write: { _ in },
                prompt: nil)
        await settle()
        sut.linkEnded("L", failed: true)
        await settle()
        XCTAssertTrue(sut.log.contains { $0.text.hasPrefix("could not put back") }, "\(sut.log.map(\.text))")
    }

    /// SEC-29. The fail-safe cannot be held off by someone else's traffic:
    /// only frames from the operator's link count as hearing them.
    func testAnotherLinksTrafficDoesNotHoldTheFailSafeOff() async {
        let sut = service("fs-other", silence: .milliseconds(400))
        sut.run(power(), argument: "5", link: "operator", facts: direct, caller: "K0EPI-3", door: "node",
                write: { _ in }, prompt: nil)
        await settle(0.2)
        sut.heard("somebody-else")
        await settle(0.5)
        XCTAssertEqual(rig.sent.last, "L RFPOWER 0.200000")
    }
}

// MARK: - Names from strangers

final class SecurityFileNameTests: XCTestCase {

    private let hostile = ["../../../etc/passwd", "/etc/passwd", "..\\..\\Windows\\System32\\x.dll", "C:\\x.zip",
                           ".ssh", "..", ".", "", "   ", "a\u{0}b.txt", "evil\u{202E}gnp.exe", "\u{1B}[31mred.txt",
                           String(repeating: "a", count: 5000) + ".txt", "con.txt\n", "~/x"]

    /// SEC-30. A received file's name can never climb out of the folder,
    /// hide, carry control characters or run on forever.
    func testReceivedFileNamesAreSafe() {
        for name in hostile {
            let safe = ReceivedFileStore.sanitize(name)
            XCTAssertFalse(safe.contains("/") || safe.contains("\\") || safe.contains(":"), "\(name.debugDescription) → \(safe)")
            XCTAssertFalse(safe.hasPrefix("."), safe)
            XCTAssertFalse(safe.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }, safe.debugDescription)
            XCTAssertLessThanOrEqual(safe.count, ReceivedFileStore.maxNameLength)
            XCTAssertFalse(safe.isEmpty)
        }
    }

    /// SEC-31. An upload's name is a short ASCII leaf, or refused.
    func testUploadNamesAreSafe() {
        for name in hostile {
            guard let safe = BBSUploadPolicy.sanitize(name) else { continue }
            XCTAssertTrue(safe.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._- ".contains($0)) },
                          "\(name.debugDescription) → \(safe)")
            XCTAssertFalse(safe.hasPrefix("."))
            XCTAssertLessThanOrEqual(safe.count, 64)
        }
    }
}

// MARK: - What a caller can make the station hold

@MainActor
final class SecurityBoundsTests: XCTestCase {

    /// SEC-32. A caller cannot set pages absurdly long or short.
    func testPagesStayInBounds() {
        var shell = BBSShell(caller: "W0ARP-1", sysop: "K0EPI-4")
        for value in ["-5", "99999999999", "1e9", "x"] {
            _ = shell.handle(line: "OP \(value)", mailbox: BBSShell.Mailbox(), now: Date())
            XCTAssertGreaterThanOrEqual(shell.pageRows, 0, value)
            XCTAssertLessThanOrEqual(shell.pageRows, 1000, value)
        }
    }

    /// SEC-33. A line of any length is answered without the station
    /// holding or echoing it all.
    func testAHugeLineIsAnsweredBriefly() {
        var shell = BBSShell(caller: "W0ARP-1", sysop: "K0EPI-4", pageRows: 0)
        let reply = shell.handle(line: String(repeating: "Z", count: 100_000), mailbox: BBSShell.Mailbox(), now: Date())
        XCTAssertLessThan(reply.lines.joined().count, 1_000)
        var node = NetRomNodeShell(nodeAlias: "EPINOD", nodeCall: "K0EPI-7", version: "AXTerm", caller: "W0ARP-1")
        let answer = node.handle(line: String(repeating: "Z", count: 100_000), snapshot: .init(), now: Date())
        XCTAssertLessThan(answer.lines.joined().count, 1_000, "at the node too")
    }

    /// SEC-33. An unknown word is said back as printable text only:
    /// binary from the caller (AXDP the node could not read, on air
    /// 2026-10-12) and control characters are not sent on the air.
    func testTheEchoIsPrintableOnly() {
        let junk = "AXT1\u{1}\u{0}\u{1B}[31m\u{7}\u{202E}x"
        let echoed = BBSShell.echo(junk)
        XCTAssertFalse(echoed.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || $0.value == 0x202E
        }, echoed.debugDescription)
        XCTAssertTrue(echoed.hasPrefix("AXT1"), echoed)
    }

    /// SEC-34. The remote-control log cannot be grown without bound by
    /// someone sending wrong codes all day.
    func testTheLogIsBounded() {
        let defaults = TestDefaults.make("sec-log-bound")
        let service = RemoteControlService(settings: BBSSettings(defaults: defaults), defaults: defaults)
        for index in 0..<(RemoteControlService.logLimit * 3) {
            service.record("gave a wrong owner code \(index)", caller: "K0EPI-3", door: "mailbox")
        }
        XCTAssertEqual(service.log.count, RemoteControlService.logLimit)
        XCTAssertEqual(service.log.last?.text, "gave a wrong owner code \(RemoteControlService.logLimit * 3 - 1)")
    }

    /// SEC-35. Every attempt is on the record: a wrong code at the mailbox
    /// and at the node both reach the log, with who and where.
    func testFailedAttemptsAreLogged() async throws {
        let defaults = TestDefaults.make("sec-log-attempts")
        let settings = BBSSettings(defaults: defaults)
        settings.ownerCommandsEnabled = true
        let service = RemoteControlService(settings: settings, defaults: defaults)
        service.ownerSecret = { Data("12345678901234567890".utf8) }
        let host = NetRomNodeHost()
        host.isEnabled = true
        host.identityProvider = { ("EPINOD", "K0EPI-7", "AXTerm") }
        host.remoteControlProvider = { service }
        host.attachAX25Caller(key: "S1", callsign: "K0EPI-3", dialed: "EPINOD", send: { _ in }, hangUp: {})
        host.ax25CallerReceived(key: "S1", data: Data("OWNER 000000\r".utf8))
        XCTAssertTrue(service.log.contains { $0.text == "gave a wrong owner code" && $0.door == "node" && $0.caller == "K0EPI-3" },
                      "\(service.log.map { "\($0.door) \($0.caller) \($0.text)" })")
    }
}
