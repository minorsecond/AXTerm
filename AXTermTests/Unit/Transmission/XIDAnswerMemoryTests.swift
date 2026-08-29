//
//  XIDAnswerMemoryTests.swift
//  AXTermTests
//
//  A DM or FRMR answering our XID is the peer's firmware speaking — a
//  fact about the station, worth keeping across launches so no connect
//  re-spends a frame and an RTO to relearn it (field capture 2026-08-28
//  19:06: AB0VZ answered DM, W0ARP-10 answered FRMR).
//

import XCTest
@testable import AXTerm

final class XIDAnswerMemoryTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "XIDAnswerMemoryTests.\(UUID().uuidString)")!
    }

    func testAnAnsweredRejectionIsRememberedAcrossLaunches() {
        let defaults = isolatedDefaults()
        var memory = XIDAnswerMemory(defaults: defaults)
        XCTAssertFalse(memory.isKnownUnsupported("W0ARP-10"))
        memory.remember("W0ARP-10", unsupported: true)
        XCTAssertTrue(memory.isKnownUnsupported("W0ARP-10"))
        XCTAssertTrue(memory.isKnownUnsupported(" w0arp-10 "),
                      "lookup is case- and padding-insensitive")

        let reloaded = XIDAnswerMemory(defaults: defaults)
        XCTAssertTrue(reloaded.isKnownUnsupported("W0ARP-10"))
    }

    /// Firmware gets upgraded: an actual XID exchange clears the memory.
    func testAnXIDAnswerClearsTheRejection() {
        let defaults = isolatedDefaults()
        var memory = XIDAnswerMemory(defaults: defaults)
        memory.remember("KB5YZB-7", unsupported: true)
        memory.remember("KB5YZB-7", unsupported: false)
        XCTAssertFalse(memory.isKnownUnsupported("KB5YZB-7"))
        XCTAssertFalse(XIDAnswerMemory(defaults: defaults).isKnownUnsupported("KB5YZB-7"))
    }

    func testDistinctSSIDsAreDistinctStations() {
        var memory = XIDAnswerMemory(defaults: isolatedDefaults())
        memory.remember("W0ARP-10", unsupported: true)
        XCTAssertFalse(memory.isKnownUnsupported("W0ARP-7"),
                       "the -7 box may run different firmware than the -10 box")
    }

    /// Firmware gets upgraded even without an XID exchange to prove it:
    /// after a month plus a per-station jitter the memory expires and the
    /// probe is asked once more.
    func testARejectionExpiresAfterItsJitteredLifetime() {
        var memory = XIDAnswerMemory(defaults: isolatedDefaults())
        let remembered = Date()
        memory.remember("W0ARP-10", unsupported: true, at: remembered)

        let lifetime = XIDAnswerMemory.revalidateAfter
            + XIDAnswerMemory.jitter(for: "W0ARP-10")
        XCTAssertTrue(memory.isKnownUnsupported(
            "W0ARP-10", now: remembered.addingTimeInterval(lifetime - 60)))
        XCTAssertFalse(memory.isKnownUnsupported(
            "W0ARP-10", now: remembered.addingTimeInterval(lifetime + 60)))
    }

    /// The jitter is deterministic per station and spreads stations apart,
    /// so a directory learned in one evening does not all come due for
    /// re-probing in the same evening a month later.
    func testExpiryJitterIsDeterministicAndSpread() {
        XCTAssertEqual(XIDAnswerMemory.jitter(for: "W0ARP-10"),
                       XIDAnswerMemory.jitter(for: "w0arp-10 "))
        XCTAssertNotEqual(XIDAnswerMemory.jitter(for: "W0ARP-10"),
                          XIDAnswerMemory.jitter(for: "AB0VZ"))
        XCTAssertLessThan(XIDAnswerMemory.jitter(for: "AB0VZ"),
                          XIDAnswerMemory.revalidateJitterSpan)
    }

    /// The V1 store was a bare list; it migrates rather than being lost.
    func testLegacyListMigrates() {
        let defaults = isolatedDefaults()
        defaults.set(["AB0VZ"], forKey: "transmission.xidUnsupportedPeers")
        let memory = XIDAnswerMemory(defaults: defaults)
        XCTAssertTrue(memory.isKnownUnsupported("AB0VZ"))
        XCTAssertNil(defaults.stringArray(forKey: "transmission.xidUnsupportedPeers"))
    }
}

/// The ping prober's XID probes get the same DM/FRMR answers a connect's
/// negotiation would — the verdict callback carries them to the session
/// layer so a probe teaches the connect path too.
final class PingProberXIDVerdictTests: XCTestCase {

    @MainActor
    private func prober() -> PingProber {
        let prober = PingProber(
            defaults: UserDefaults(suiteName: "PingProberXIDVerdictTests.\(UUID().uuidString)")!)
        prober.sendFrame = { _ in true }
        prober.localAddress = { AX25Address(call: "K0EPI", ssid: 7) }
        return prober
    }

    @MainActor
    func testFRMRAnsweringTheXIDProbeIsAPre22Verdict() async {
        let prober = prober()
        var verdicts: [(String, Bool)] = []
        prober.onXIDVerdict = { verdicts.append(($0, $1)) }
        let start = Date()
        prober.probeNow("W0ARP-10", at: start)
        prober.noteAnswer(from: "W0ARP-10", uType: .FRMR, hasSession: false,
                          at: start.addingTimeInterval(2))
        XCTAssertEqual(verdicts.count, 1)
        XCTAssertEqual(verdicts.first?.0, "W0ARP-10")
        XCTAssertEqual(verdicts.first?.1, true)
    }

    @MainActor
    func testAnXIDAnswerIsAV22Verdict() async {
        let prober = prober()
        var verdicts: [(String, Bool)] = []
        prober.onXIDVerdict = { verdicts.append(($0, $1)) }
        let start = Date()
        prober.probeNow("N0V22-1", at: start)
        prober.noteAnswer(from: "N0V22-1", uType: .XID, hasSession: false,
                          at: start.addingTimeInterval(1))
        XCTAssertEqual(verdicts.first?.1, false)
    }

    /// DM answering the DISC fallback is the *normal* §6.3.4 reply from any
    /// stack, v2.2 included — it must not be read as an XID verdict.
    @MainActor
    func testDMAnsweringTheDISCFallbackIsNoVerdict() async {
        let prober = prober()
        var verdicts: [(String, Bool)] = []
        prober.onXIDVerdict = { verdicts.append(($0, $1)) }
        let start = Date()
        prober.probeNow("AB0VZ", at: start)
        // XID goes unanswered; the tick escalates to the DISC probe.
        prober.tick(now: start.addingTimeInterval(PingProber.answerTimeout + 1))
        prober.noteAnswer(from: "AB0VZ", uType: .DM, hasSession: false,
                          at: start.addingTimeInterval(PingProber.answerTimeout + 3))
        XCTAssertTrue(verdicts.isEmpty)
    }
}
