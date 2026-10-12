//
//  SecurityOwnerCodeStateTests.swift
//  AXTermTests
//
//  Security suite (Docs/SecurityTesting.md): the code checker's memory.
//  Which code was used last and how long codes are locked out are kept in
//  preferences, so a restart neither lets a heard code be used again nor
//  ends a lockout. The operator can see a lockout on the Remote Control
//  page and clear it there, and every wrong code is logged with the path
//  it claimed.
//

import XCTest
@testable import AXTerm

@MainActor
final class SecurityOwnerCodeStateTests: XCTestCase {

    private let secret = Data("12345678901234567890".utf8)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func station(_ defaults: UserDefaults) -> RemoteControlService {
        let settings = BBSSettings(defaults: defaults)
        settings.ownerCommandsEnabled = true
        let service = RemoteControlService(settings: settings, defaults: defaults)
        service.ownerSecret = { [secret] in secret }
        return service
    }

    private func check(_ code: String, at date: Date, on service: RemoteControlService) -> OwnerCode.Verdict {
        service.codeCheck(for: "K0EPI-3", station: "K0EPI-4")!(code, date)
    }

    /// SEC-36. A code heard on the air cannot be used again after AXTerm
    /// restarts.
    func testAUsedCodeStaysUsedAfterARestart() {
        let defaults = TestDefaults.make("sec-code-restart-used")
        let code = OwnerCode.code(secret: secret, at: start)
        XCTAssertEqual(check(code, at: start, on: station(defaults)), .accepted)
        XCTAssertEqual(check(code, at: start.addingTimeInterval(20), on: station(defaults)), .used)
    }

    /// SEC-37. A lockout, and how long the next one will be, hold across a
    /// restart.
    func testALockoutHoldsAfterARestart() {
        let defaults = TestDefaults.make("sec-code-restart-lockout")
        let first = station(defaults)
        for _ in 0..<3 { _ = check("000000", at: start, on: first) }
        let right = OwnerCode.code(secret: secret, at: start.addingTimeInterval(60))
        XCTAssertEqual(check(right, at: start.addingTimeInterval(60), on: station(defaults)), .lockedOut)
        XCTAssertNotNil(RemoteControlService.codeLockedUntil(defaults: defaults, now: start.addingTimeInterval(60)))

        // The second lockout is twice the first, after a restart too.
        let after = start.addingTimeInterval(OwnerCode.Checker.lockout + 1)
        let second = station(defaults)
        for _ in 0..<3 { _ = check("000000", at: after, on: second) }
        let later = after.addingTimeInterval(OwnerCode.Checker.lockout + 1)
        XCTAssertEqual(check(OwnerCode.code(secret: secret, at: later), at: later, on: station(defaults)), .lockedOut)
    }

    /// SEC-38. The operator sees a lockout and can clear it at the station.
    /// Clearing it is logged, and a used code stays used.
    func testTheOperatorCanClearALockout() {
        let defaults = TestDefaults.make("sec-code-clear")
        let service = station(defaults)
        let used = OwnerCode.code(secret: secret, at: start)
        XCTAssertEqual(check(used, at: start, on: service), .accepted)
        let soon = start.addingTimeInterval(10)
        for _ in 0..<3 { _ = check("000000", at: soon, on: service) }
        let until = RemoteControlService.codeLockedUntil(defaults: defaults, now: soon)
        XCTAssertEqual(until, soon.addingTimeInterval(OwnerCode.Checker.lockout))

        RemoteControlService.clearCodeLockout(defaults: defaults, by: "the operator at the station", now: soon)

        XCTAssertNil(RemoteControlService.codeLockedUntil(defaults: defaults, now: soon))
        XCTAssertEqual(check(used, at: soon, on: service), .used, "a heard code is still spent")
        let next = start.addingTimeInterval(30)
        XCTAssertEqual(check(OwnerCode.code(secret: secret, at: next), at: next, on: service), .accepted)
        XCTAssertTrue(RemoteControlService.storedLog(defaults: defaults).contains {
            $0.text == "cleared the code lockout" && $0.caller == "the operator at the station"
        })
        XCTAssertTrue(service.log.contains { $0.text == "cleared the code lockout" },
                      "the station's own log shows it too")
    }

    /// SEC-38. A lockout that has run out is not shown.
    func testALockoutThatRanOutIsNotShown() {
        let defaults = TestDefaults.make("sec-code-ran-out")
        let service = station(defaults)
        for _ in 0..<3 { _ = check("000000", at: start, on: service) }
        XCTAssertNil(RemoteControlService.codeLockedUntil(
            defaults: defaults, now: start.addingTimeInterval(OwnerCode.Checker.lockout + 1)))
        XCTAssertNil(RemoteControlService.codeLockedUntil(defaults: TestDefaults.make("sec-code-none"), now: start))
    }

    /// SEC-39. A wrong code is logged with the path it came over, so
    /// someone sending them can be found.
    func testAWrongCodeIsLoggedWithItsPath() {
        let defaults = TestDefaults.make("sec-code-path")
        let service = station(defaults)
        let host = NetRomNodeHost()
        host.isEnabled = true
        host.identityProvider = { ("EPINOD", "K0EPI-7", "AXTerm") }
        host.remoteControlProvider = { service }
        host.attachAX25Caller(key: "S1", callsign: "K0EPI-3", dialed: "EPINOD", digipeated: true,
                              via: ["W0ABC-1", "W0XYZ-2"], send: { _ in }, hangUp: {})
        host.ax25CallerReceived(key: "S1", data: Data("OWNER 000000\r".utf8))
        XCTAssertTrue(service.log.contains { $0.text == "gave a wrong owner code via W0ABC-1,W0XYZ-2" },
                      "\(service.log.map(\.text))")
    }

    /// SEC-39. Over a NET/ROM circuit, the log says so.
    func testAWrongCodeOverACircuitSaysSo() {
        XCTAssertEqual(RemoteControlService.LinkFacts(radio: nil, digipeated: false, relayed: true).route,
                       " through a NET/ROM circuit")
        XCTAssertEqual(RemoteControlService.LinkFacts(radio: nil, digipeated: true, relayed: false).route,
                       " through a digipeater")
        XCTAssertEqual(RemoteControlService.LinkFacts(radio: nil, digipeated: false, relayed: false).route, "")
    }
}
