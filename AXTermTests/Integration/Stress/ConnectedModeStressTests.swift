//
//  ConnectedModeStressTests.swift
//  AXTermTests
//
//  AX.25 connected mode end to end on a simulated half-duplex channel: two
//  real session managers, a seeded channel with airtime, carrier sense,
//  collisions, transmitter hang, loss, fades and an optional digipeater
//  (HalfDuplexChannel), and the invariants in ConnectedModeStress.swift
//  checked on every run.
//
//  The scenarios come from the live RF findings of 2026-09-30 and
//  2026-10-01 (Docs/LiveRFTest-2026-09-30.md): half-duplex turnaround
//  collisions, a receiver's 2 s T2 firing mid-burst, T1 shorter than the
//  peer's delayed ack, a 0.7 s transmitter tail and a lossy USB link.
//
//  Every run is reproducible from its seed, and a failure prints the seed,
//  the scenario and the tail of the channel trace. The normal run uses a
//  few seeds per family. AXTERM_STRESS_SEEDS=<n> (passed to xcodebuild as
//  TEST_RUNNER_AXTERM_STRESS_SEEDS) runs n seeds per family instead.
//  Each family writes its figures to the test host's temporary directory,
//  AXTermStress/<family>.txt.
//

import XCTest
@testable import AXTerm

@MainActor
final class ConnectedModeStressTests: XCTestCase {

    // MARK: Seeds

    private static var soakSeeds: Int? {
        ProcessInfo.processInfo.environment["AXTERM_STRESS_SEEDS"].flatMap(Int.init)
    }

    private func seeds(_ normal: Int) -> [UInt64] {
        (1...(Self.soakSeeds ?? normal)).map(UInt64.init)
    }

    /// Picks parameters for a seed, independent of the channel's draws.
    private struct Picker {
        var rng: RFRng
        init(_ seed: UInt64, _ salt: UInt64) { rng = RFRng(seed: seed &* 0x9E37_79B9 ^ salt) }
        mutating func pick<T>(_ options: [T]) -> T { options[Int(rng.next() % UInt64(options.count))] }
        mutating func uniform(_ lo: Double, _ hi: Double) -> Double { rng.uniform(lo, hi) }
        mutating func chance(_ p: Double) -> Bool { rng.chance(p) }
    }

    // MARK: Running a family

    @discardableResult
    private func runFamily(_ family: String, seeds: [UInt64], requireCompletion: Bool = false,
                           expectIncomplete: ((StressScenario, StressResult) -> String?)? = nil,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ make: (UInt64) -> StressScenario,
                           onResult: (StressResult) -> Void = { _ in }) -> StressTally {
        var tally = StressTally()
        var lines: [String] = []
        for seed in seeds {
            let scenario = make(seed)
            let result = StressRunner(scenario).run()
            onResult(result)
            tally.add(result)
            lines.append(result.summary)
            lines.append(contentsOf: result.gapFlushLosses.map { "  gap flush: \($0)" })
            lines.append(contentsOf: result.violations.map { "  violation: \($0)" })
            if !result.gapFlushLosses.isEmpty {
                // Owner's design, not changed here: AX25StateMachine's
                // last-ditch receive-gap flush at T1 retry N2-1 skips a frame
                // the peer may still be retransmitting, and tells nobody.
                XCTExpectFailure("Receive-gap flush lost data without reporting it (documented deviation in AX25StateMachine.t1Timeout); reported, not fixed") {
                    XCTFail("\(family) seed \(seed): \(scenario)\n\(result.gapFlushLosses.joined(separator: "\n"))",
                            file: file, line: line)
                }
            }
            let streamOnly = result.violations.allSatisfy { $0.contains("stream differs") || $0.contains("duplicated data") }
            // The stale frames that cause it ride the same transmission as
            // the UA, so the break can show a moment before the UA is read.
            let afterUA = result.firstUnexpectedUA.map { ua in (result.firstViolationAt ?? 0) >= ua - 5 } ?? false
            if !result.violations.isEmpty, afterUA, streamOnly {
                // AX.25 2.2's SDL answers a UA in the connected state with
                // error C and a fresh SABM; AXTerm ignores it, so a link reset
                // the other side made (for a stale, retransmitted SABM) leaves
                // the two sequence states apart. Reported, not changed here.
                XCTExpectFailure("UA received while connected was ignored (AX.25 2.2 SDL: re-establish, error C); the peer's reset left the sequence states apart; reported, not fixed") {
                    XCTFail("\(family) seed \(seed): \(scenario)\n\(result.violations.joined(separator: "\n"))",
                            file: file, line: line)
                }
            } else if !result.violations.isEmpty {
                XCTFail("""
                    \(family) seed \(seed) broke an invariant: \(scenario)
                    \(result.violations.joined(separator: "\n"))
                    trace:
                    \(result.trace.suffix(40).joined(separator: "\n"))
                    """, file: file, line: line)
            }
            if requireCompletion, !result.completed {
                if let note = expectIncomplete?(scenario, result) {
                    XCTExpectFailure(note) {
                        XCTFail("\(family) seed \(seed) did not complete: \(result.summary)", file: file, line: line)
                    }
                } else {
                    XCTFail("\(family) seed \(seed) did not complete: \(result.summary)", file: file, line: line)
                }
            }
        }
        lines.append("TOTAL \(tally.row)")
        StressReport.write(lines, name: family)
        return tally
    }

    /// Through a digipeater the two stations cannot hear each other, so
    /// carrier sense cannot separate them. When their transmissions collide
    /// at the digipeater, both retry after the same fixed T1 (FRACK times
    /// three for one hop, backing off identically) and collide again, every
    /// time, until N2. T1 has no jitter; behavior, reported, not changed.
    static func hiddenLockStep(_ scenario: StressScenario, _ result: StressResult) -> String? {
        guard scenario.viaDigi, result.linkFailed, result.collisions > 0 else { return nil }
        return "Hidden stations through a digipeater: T1 has no jitter, so retries that collided once stay in step and collide until N2 (behavior, reported)"
    }

    // MARK: Clean channels

    /// No loss: every byte arrives, at both rates, direct and through a
    /// digipeater, for every K and a spread of paclens, both sides sending.
    func testCleanChannelDeliversEverythingAcrossTheMatrix() {
        var cases: [(Double, Bool, Int, Int)] = []
        for rate in [1200.0, 9600.0] {
            for digi in [false, true] {
                for k in 1...4 {
                    for p in [64, 128, 256] { cases.append((rate, digi, k, p)) }
                }
            }
        }
        let tally = runFamily("clean", seeds: (1...UInt64(cases.count * (Self.soakSeeds.map { max(1, $0 / 10) } ?? 1))).map { $0 },
                              requireCompletion: true, expectIncomplete: Self.hiddenLockStep) { seed in
            let c = cases[Int(seed - 1) % cases.count]
            var s = StressScenario(name: "clean", seed: seed)
            s.bitRate = c.0
            s.viaDigi = c.1
            s.window = c.2
            s.paclen = c.3
            s.traffic = .bulk(aToB: 3000, bToA: 1500)
            return s
        }
        XCTAssertGreaterThan(tally.completed, 0)
    }

    // MARK: Lossy, bursty and collision-prone channels

    func testLossyChannelsDeliverInOrderOrFailCleanly() {
        runFamily("lossy", seeds: seeds(24)) { seed in
            var pick = Picker(seed, 0x1055)
            var s = StressScenario(name: "lossy", seed: seed)
            s.loss = pick.pick([0.05, 0.1, 0.2, 0.3, 0.4])
            s.bitRate = pick.pick([1200, 9600])
            s.viaDigi = pick.chance(0.3)
            s.window = pick.pick([1, 2, 3, 4])
            s.paclen = pick.pick([64, 128, 192, 256])
            s.traffic = .bulk(aToB: 2500, bToA: pick.pick([0, 800]))
            return s
        }
    }

    func testFadesDeliverInOrderOrFailCleanly() {
        runFamily("fades", seeds: seeds(16)) { seed in
            var pick = Picker(seed, 0xFADE)
            var s = StressScenario(name: "fades", seed: seed)
            s.fade = SimFadeModel(meanClear: pick.pick([20, 40, 90]), meanFade: pick.pick([2, 6, 15]))
            s.loss = pick.pick([0, 0.02])
            s.bitRate = pick.pick([1200, 9600])
            s.viaDigi = pick.chance(0.3)
            s.window = pick.pick([1, 2, 4])
            s.paclen = pick.pick([64, 128, 256])
            s.traffic = .bulk(aToB: 2500, bToA: 600)
            return s
        }
    }

    /// Both sides pushing bulk data at once, with TNCs that key at the first
    /// clear slot and notice a carrier late, so their transmissions overlap.
    func testCollisionProneChannelsDeliverInOrderOrFailCleanly() {
        runFamily("collisions", seeds: seeds(16)) { seed in
            var pick = Picker(seed, 0xC011)
            var s = StressScenario(name: "collisions", seed: seed)
            s.persistence = pick.pick([127, 255])
            s.slotTime = pick.pick([0.01, 0.05])
            s.bitRate = pick.pick([1200, 9600])
            s.viaDigi = pick.chance(0.4)
            s.window = pick.pick([2, 3, 4])
            s.paclen = pick.pick([128, 256])
            s.loss = pick.pick([0, 0.05])
            s.traffic = .bulk(aToB: 2500, bToA: 2500)
            return s
        }
    }

    func testDuplicatesAndALossyUSBLinkDeliverInOrderOrFailCleanly() {
        runFamily("duplicates-usb", seeds: seeds(12)) { seed in
            var pick = Picker(seed, 0xD0B)
            var s = StressScenario(name: "duplicates-usb", seed: seed)
            s.duplicate = pick.pick([0.05, 0.2])
            s.hostDrop = pick.pick([0, 0.05, 0.15])
            s.loss = pick.pick([0, 0.1])
            s.viaDigi = pick.chance(0.3)
            s.window = pick.pick([1, 2, 4])
            s.traffic = .bulk(aToB: 2500, bToA: 800)
            return s
        }
    }

    // MARK: Turnaround

    /// The 705 tail and its friends: the peer's transmitter hang from 0 to
    /// 1 s, TX delay from 100 ms to 1 s, FRACK from 3 to 8 s.
    func testTurnaroundStressDeliversInOrderOrFailsCleanly() {
        runFamily("turnaround", seeds: seeds(24)) { seed in
            var pick = Picker(seed, 0x7A12)
            var s = StressScenario(name: "turnaround", seed: seed)
            s.hang = (pick.pick([0, 0.3, 0.7, 1.0]), pick.pick([0, 0.3]))
            s.txDelay = (pick.pick([0.1, 0.3, 0.5]), pick.pick([0.1, 0.3, 0.8, 1.0]))
            s.frack = pick.pick([3, 4, 6, 8])
            s.loss = pick.pick([0, 0.05])
            s.window = pick.pick([1, 2, 4])
            s.paclen = pick.pick([128, 256])
            s.traffic = .bulk(aToB: 2500, bToA: pick.pick([0, 1000]))
            return s
        }
    }

    // MARK: Chat

    func testLongChatBothWays() {
        runFamily("chat", seeds: seeds(10)) { seed in
            var pick = Picker(seed, 0xC4A7)
            var s = StressScenario(name: "chat", seed: seed)
            s.loss = pick.pick([0, 0.05, 0.15])
            s.hang = (pick.pick([0, 0.7]), 0)
            s.viaDigi = pick.chance(0.3)
            s.traffic = .chat(linesEach: 40, meanGap: pick.pick([2, 8, 20]), bothWays: true)
            return s
        }
    }

    // MARK: Links that end mid-transfer

    /// Either side disconnects partway through a two-way transfer: both end
    /// disconnected, both say so, and what arrived is an exact prefix.
    func testDisconnectMidTransferEndsCleanlyOnBothSides() {
        runFamily("disconnect-mid-transfer", seeds: seeds(12)) { seed in
            var pick = Picker(seed, 0xD15C)
            var s = StressScenario(name: "disconnect-mid-transfer", seed: seed)
            s.loss = pick.pick([0, 0.1])
            s.viaDigi = pick.chance(0.3)
            s.hang = (pick.pick([0, 0.7]), 0)
            s.traffic = .bulk(aToB: 20000, bToA: 6000)
            s.events = [.disconnect(at: pick.uniform(15, 120), station: pick.pick([0, 1]))]
            return s
        }
    }

    /// The far radio is switched off mid-transfer: both sides retry to N2,
    /// give up and report it.
    func testRadioOffMidTransferExhaustsN2OnBothSides() {
        let tally = runFamily("radio-off", seeds: seeds(8)) { seed in
            var pick = Picker(seed, 0x0FF)
            var s = StressScenario(name: "radio-off", seed: seed)
            s.loss = pick.pick([0, 0.05])
            s.viaDigi = pick.chance(0.3)
            s.traffic = .bulk(aToB: 20000, bToA: pick.pick([0, 5000]))
            s.events = [.power(at: pick.uniform(20, 90), station: pick.pick([0, 1]), on: false)]
            return s
        }
        XCTAssertEqual(tally.failed, tally.runs, "every link must end failed")
    }

    /// One direction dies: the station whose frames no longer get through
    /// exhausts N2. The other side still hears it and polls it; how long it
    /// takes to learn the link is gone is recorded.
    func testOneWayOutageFailsBothSides() {
        var lags: [String] = []
        let tally = runFamily("one-way-outage", seeds: seeds(8)) { seed in
            var pick = Picker(seed, 0x1A7)
            var s = StressScenario(name: "one-way-outage", seed: seed)
            s.viaDigi = pick.chance(0.3)
            s.traffic = .bulk(aToB: 20000, bToA: pick.pick([0, 4000]))
            s.oneWayOutage = (from: pick.pick([0, 1]), start: pick.uniform(20, 60))
            return s
        } onResult: { result in
            lags.append(String(format: "%.0f", result.failureLag ?? -1))
        }
        XCTAssertEqual(tally.failed, tally.runs)
        StressReport.write(["failure lags (s): " + lags.joined(separator: " ")], name: "one-way-outage-lag")
    }

    /// The channel dies long enough for the sending side to exhaust N2,
    /// then comes back while the receiving side, which only polls on T3,
    /// still holds the link. Its polls now reach a station that has given
    /// up; how long it takes to learn that is recorded.
    func testTransientOutageLeavesNoStaleSession() {
        var lags: [String] = []
        let tally = runFamily("transient-outage", seeds: seeds(8)) { seed in
            var pick = Picker(seed, 0x7A0)
            var s = StressScenario(name: "transient-outage", seed: seed)
            s.viaDigi = pick.chance(0.3)
            s.traffic = .bulk(aToB: 40000, bToA: 0)
            let start = pick.uniform(20, 40)
            // Long enough for A's 15 retries to run out (about 400 s with
            // the RTO backing off to 30 s), short enough that B, whose T3
            // only starts polling after 30 s of quiet, is still trying.
            s.outages = [start...(start + 420)]
            return s
        } onResult: { result in
            lags.append(String(format: "%.0f", result.failureLag ?? -1))
        }
        StressReport.write(["failure lags (s): " + lags.joined(separator: " "), "TOTAL \(tally.row)"],
                           name: "transient-outage-lag")
    }

    /// The far station crashes and comes back with no session, and does not
    /// call again: the survivor's next poll draws DM and it reports the
    /// link down instead of retrying into a station that forgot it.
    func testPeerRestartWithoutReconnectFailsTheStaleSessionCleanly() {
        let tally = runFamily("restart-stale", seeds: seeds(8)) { seed in
            var pick = Picker(seed, 0x5A1E)
            var s = StressScenario(name: "restart-stale", seed: seed)
            s.loss = pick.pick([0, 0.05])
            s.viaDigi = pick.chance(0.3)
            s.traffic = .bulk(aToB: 20000, bToA: 4000)
            s.events = [.restart(at: pick.uniform(20, 90), station: pick.pick([0, 1]), reconnect: false)]
            return s
        }
        XCTAssertEqual(tally.failed, tally.runs)
    }

    /// The far station crashes mid-transfer and calls straight back. The
    /// survivor's session receives SABM while connected: a link reset.
    func testPeerRestartAndReconnectMidTransfer() {
        runFamily("restart-reconnect", seeds: seeds(8)) { seed in
            var pick = Picker(seed, 0x5A1F)
            var s = StressScenario(name: "restart-reconnect", seed: seed)
            s.loss = pick.pick([0, 0.05])
            s.traffic = .bulk(aToB: 8000, bToA: 2000)
            s.events = [.restart(at: pick.uniform(20, 60), station: 1, reconnect: true)]
            return s
        }
    }

    /// Both stations call each other in the same instant (SABM collision,
    /// AX.25 2.2 §6.3.3). One link comes up and carries data both ways.
    ///
    /// With TNCs at persistence 255, two calls in the same instant (or
    /// within a SABM's airtime through a digipeater both stations hear but
    /// that cannot hear each other's key-up) never separate: T1 has no
    /// jitter, both retry FRACK after their own SABM, and every retry
    /// collides again until N2. Kept as data and expected to fail; at the
    /// KISS default persistence of 63 the calls always separate.
    func testSimultaneousConnectStillCarriesData() {
        let lockStep = "Persistence 255 and simultaneous calls: T1 has no jitter, so the SABM retries stay in step and collide until N2 (behavior, reported)"
        let tally = runFamily("sabm-collision", seeds: seeds(12), requireCompletion: true,
                              expectIncomplete: { scenario, result in
                                  if scenario.persistence == 255 { return lockStep }
                                  return Self.hiddenLockStep(scenario, result)
                              }) { seed in
            var pick = Picker(seed, 0x5AB)
            var s = StressScenario(name: "sabm-collision", seed: seed)
            s.connectOffset = pick.pick([0, 0, 0.05, 0.2, 0.6])
            s.persistence = pick.pick([63, 255])
            s.viaDigi = pick.chance(0.3)
            s.traffic = .bulk(aToB: 2000, bToA: 2000)
            return s
        }
        XCTAssertGreaterThan(tally.completed, 0)
    }

    // MARK: Defaults against the switched-off alternatives

    /// The same scenarios under the production defaults (FRACK floor under
    /// T1, in-session growth off), with SessionCoordinator.inSessionLinkGrowth
    /// on, and with AX25SessionManager.useDelayedAckT1 on. Data for the
    /// owner: the invariants must hold in every mode, and the figures go to
    /// AXTermStress/mode-comparison.txt. No default is changed.
    func testModeComparison() {
        struct Case { let name: String; let make: (inout StressScenario) -> Void }
        let cases: [Case] = [
            Case(name: "field-705") { s in
                // 2026-09-30: the 705 through Warbler (0.7 s hang) and the
                // TNC4 at 800 ms TX delay; 20 KB from B to A.
                s.hang = (0.7, 0); s.txDelay = (0.3, 0.8)
                s.traffic = .bulk(aToB: 0, bToA: 20000)
            },
            Case(name: "field-705-txd300") { s in
                s.hang = (0.7, 0); s.txDelay = (0.3, 0.3)
                s.traffic = .bulk(aToB: 0, bToA: 20000)
            },
            Case(name: "field-705-loss10") { s in
                s.hang = (0.7, 0); s.txDelay = (0.3, 0.8); s.loss = 0.1
                s.traffic = .bulk(aToB: 0, bToA: 20000)
            },
            Case(name: "clean-1200") { s in s.traffic = .bulk(aToB: 20000, bToA: 0) },
            Case(name: "clean-9600") { s in s.bitRate = 9600; s.traffic = .bulk(aToB: 20000, bToA: 0) },
            Case(name: "two-way-1200") { s in s.traffic = .bulk(aToB: 8000, bToA: 8000) },
            Case(name: "loss20-1200") { s in s.loss = 0.2; s.traffic = .bulk(aToB: 10000, bToA: 0) },
            Case(name: "fades-1200") { s in
                s.fade = SimFadeModel(meanClear: 40, meanFade: 5); s.traffic = .bulk(aToB: 10000, bToA: 0)
            },
            Case(name: "digi-1200") { s in s.viaDigi = true; s.traffic = .bulk(aToB: 10000, bToA: 0) },
            Case(name: "chat-slow-peer-frack3") { s in
                // Lone unpolled lines to a slow peer: 1 s TX delay, the
                // 705's hang on our side, FRACK at its 3 s minimum.
                s.hang = (0.7, 0); s.txDelay = (0.3, 1.0); s.frack = 3
                s.traffic = .chat(linesEach: 30, meanGap: 6, bothWays: true)
            },
            Case(name: "bulk-K4-P256-1200") { s in
                // Four 256-byte frames hold a 1200 baud channel about 7.5 s,
                // longer than the 4 s FRACK floor. (Fixed K and paclen, so
                // growth has nothing to do here.)
                s.window = 4; s.paclen = 256
                s.traffic = .bulk(aToB: 20000, bToA: 0)
            },
            Case(name: "chat-705") { s in
                s.hang = (0.7, 0); s.txDelay = (0.3, 0.3)
                s.traffic = .chat(linesEach: 30, meanGap: 6, bothWays: true)
            }
        ]
        var lines: [String] = []
        var totals: [StressMode: StressTally] = [:]
        for c in cases {
            for mode in StressMode.allCases {
                let tally = runFamily("mode-\(c.name)-\(mode.rawValue)", seeds: seeds(4)) { seed in
                    var s = StressScenario(name: c.name, seed: seed)
                    s.mode = mode
                    c.make(&s)
                    return s
                }
                lines.append("\(c.name) \(mode.rawValue): \(tally.row)")
                var total = totals[mode] ?? StressTally()
                total.merge(tally)
                totals[mode] = total
            }
        }
        for mode in StressMode.allCases {
            lines.append("ALL \(mode.rawValue): \(totals[mode]?.row ?? "")")
        }
        StressReport.write(lines, name: "mode-comparison")
    }

    // MARK: Determinism

    func testTheSameSeedReplaysTheSameRun() {
        var s = StressScenario(name: "replay", seed: 77)
        s.loss = 0.15
        s.duplicate = 0.05
        s.hang = (0.7, 0)
        s.fade = SimFadeModel(meanClear: 40, meanFade: 4)
        s.traffic = .bulk(aToB: 3000, bToA: 1000)
        let first = StressRunner(s).run()
        let second = StressRunner(s).run()
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.trace, second.trace)
        s.seed = 78
        XCTAssertNotEqual(StressRunner(s).run().fingerprint, first.fingerprint)
    }
}
