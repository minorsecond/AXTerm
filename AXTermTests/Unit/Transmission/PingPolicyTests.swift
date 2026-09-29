import XCTest
@testable import AXTerm

/// Every rule here is a reason not to transmit. The tests are mostly
/// about the app staying off the air.
final class PingPolicyTests: XCTestCase {

    private let noon = Calendar.current.date(
        from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!

    private func settings(
        _ mutate: (inout PingPolicy.Settings) -> Void = { _ in }
    ) -> PingPolicy.Settings {
        var s = PingPolicy.Settings()
        s.enabled = true
        mutate(&s)
        return s
    }

    private func conditions(
        _ mutate: (inout PingPolicy.Conditions) -> Void = { _ in }
    ) -> PingPolicy.Conditions {
        var c = PingPolicy.Conditions(
            now: noon, lastProbeAt: nil, probesInLastHour: [],
            lastTrafficAt: nil, connectedPeers: [])
        mutate(&c)
        return c
    }

    private func candidate(
        _ call: String, source: PingPolicy.Source = .heardDirect
    ) -> PingPolicy.Candidate {
        PingPolicy.Candidate(call: call, source: source, lastActivity: noon)
    }

    // MARK: - Reasons not to transmit

    func testOffMeansOff() {
        var s = settings(); s.enabled = false
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-10")], histories: [:],
                              settings: s, conditions: conditions()),
            .hold("pinging is off"))
    }

    func testOutsideTheWindowNothingGoesOut() {
        let s = settings { $0.windowStartHour = 8; $0.windowEndHour = 10 }
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-10")], histories: [:],
                              settings: s, conditions: conditions()),
            .hold("outside the chosen hours"))
    }

    /// A probe dropped into somebody else's exchange collides, and they
    /// get to wonder why their link went bad.
    func testABusyChannelDefersTheProbe() {
        let c = conditions { $0.lastTrafficAt = self.noon.addingTimeInterval(-3) }
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-10")], histories: [:],
                              settings: settings(), conditions: c),
            .hold("the channel is busy"))
    }

    /// Our own session is traffic too, and interrupting it is worse:
    /// it is the operator's transfer we would be stepping on.
    func testALiveSessionStopsEverything() {
        let c = conditions { $0.connectedPeers = ["DRLNOD"] }
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-10")], histories: [:],
                              settings: settings(), conditions: c),
            .hold("a session is running"))
    }

    func testTheHourlyBudgetIsAHardCeiling() {
        let s = settings { $0.maxProbesPerHour = 2 }
        let c = conditions {
            $0.probesInLastHour = [self.noon.addingTimeInterval(-600),
                                   self.noon.addingTimeInterval(-1200)]
        }
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-10")], histories: [:],
                              settings: s, conditions: c),
            .hold("hourly budget spent"))
    }

    /// Probes older than an hour have left the budget.
    func testTheBudgetIsATrailingHour() {
        let s = settings { $0.maxProbesPerHour = 1 }
        let c = conditions { $0.probesInLastHour = [self.noon.addingTimeInterval(-3700)] }
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-10")], histories: [:],
                              settings: s, conditions: c),
            .probe("K0NTS-10"))
    }

    func testProbesAreSpacedOut() {
        let s = settings { $0.minSecondsBetweenProbes = 120 }
        let c = conditions { $0.lastProbeAt = self.noon.addingTimeInterval(-30) }
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-10")], histories: [:],
                              settings: s, conditions: c),
            .hold("too soon after the last probe"))
    }

    /// Jitter stretches the spacing by up to half again, so the prober is
    /// never a metronome — and never in lockstep with someone's beacon.
    func testSpacingJitterStretchesTheGap() {
        let s = settings { $0.minSecondsBetweenProbes = 120 }
        // 150 s since the last probe: past the base spacing, inside the
        // fully-jittered one (180 s).
        let c = conditions {
            $0.lastProbeAt = self.noon.addingTimeInterval(-150)
            $0.spacingJitter = 1
        }
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-10")], histories: [:],
                              settings: s, conditions: c),
            .hold("too soon after the last probe"))

        var relaxed = c
        relaxed.spacingJitter = 0
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-10")], histories: [:],
                              settings: s, conditions: relaxed),
            .probe("K0NTS-10"))
    }

    /// K0EPI-6 is DRLNOD's transmitter wearing this station's licence — a
    /// node's borrowed dial-out leg. A ping to any SSID of our own base
    /// callsign teaches nothing about anyone's coverage (field capture
    /// 2026-08-29 05:05: XID sent to K0EPI-6).
    func testOurOwnBaseCallsignIsNeverProbed() {
        let c = conditions { $0.localCallsign = "K0EPI-7" }
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0EPI-6")], histories: [:],
                              settings: settings(), conditions: c),
            .hold("nothing is due"))
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0EPI-6"), candidate("AB0VZ")],
                              histories: [:], settings: settings(), conditions: c),
            .probe("AB0VZ"))
    }

    /// DRLNOD addresses its node link to bare KB5YZB, so the prober
    /// overheard a "station" that never transmits under that name — while
    /// KB5YZB-7, the box's real voice, was already in the rotation (field
    /// capture 2026-08-29 05:19: XID sent to KB5YZB).
    func testASilentAlternateAddressOfAKnownStationIsNotProbed() {
        let both = [candidate("KB5YZB-7"),
                    candidate("KB5YZB", source: .calledByOthers)]
        let s = settings { $0.sources = [.heardDirect, .calledByOthers] }
        XCTAssertEqual(
            PingPolicy.decide(candidates: both, histories: [:],
                              settings: s, conditions: conditions()),
            .probe("KB5YZB-7"))
        // A callee nobody of that base was heard from is still genuinely
        // new — WN6OTL only ever appears as a destination.
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-10"),
                                           candidate("WN6OTL", source: .calledByOthers)],
                              histories: ["K0NTS-10": PingPolicy.History(
                                lastProbed: noon.addingTimeInterval(-60),
                                lastAnswered: nil, consecutiveSilences: 0)],
                              settings: s, conditions: conditions()),
            .probe("WN6OTL"))
    }

    /// Already connected: it is demonstrably hearing us.
    func testAConnectedStationIsNotProbed() {
        let c = conditions { $0.connectedPeers = ["DRLNOD"] }
        // Not the "session is running" branch — that fires first — so give
        // the policy a session with a station that is not a candidate.
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("DRLNOD")], histories: [:],
                              settings: settings(), conditions: c),
            .hold("a session is running"))
    }

    /// Speculative candidates are opt-in.
    func testStationsOnlyOthersCallAreSkippedByDefault() {
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("KN6VV-1", source: .calledByOthers)],
                              histories: [:], settings: settings(), conditions: conditions()),
            .hold("nothing is due"))
    }

    func testEnablingTheSecondSourceIncludesThem() {
        let s = settings { $0.sources = [.heardDirect, .calledByOthers] }
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("KN6VV-1", source: .calledByOthers)],
                              histories: [:], settings: s, conditions: conditions()),
            .probe("KN6VV-1"))
    }

    // MARK: - Choosing

    func testTheLongestUnprobedGoesFirst() {
        let histories = [
            "K0NTS-10": PingPolicy.History(lastProbed: noon.addingTimeInterval(-7200)),
            "AB0VZ": PingPolicy.History(lastProbed: noon.addingTimeInterval(-90000))
        ]
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-10"), candidate("AB0VZ")],
                              histories: histories, settings: settings(),
                              conditions: conditions()),
            .probe("AB0VZ"))
    }

    /// Determinism: the same inputs pick the same station, whatever order
    /// the candidates arrived in.
    func testNeverProbedBeatsProbedAndTiesBreakByCallsign() {
        let forward = PingPolicy.decide(
            candidates: [candidate("W0TX"), candidate("AB0VZ")],
            histories: [:], settings: settings(), conditions: conditions())
        let reversed = PingPolicy.decide(
            candidates: [candidate("AB0VZ"), candidate("W0TX")],
            histories: [:], settings: settings(), conditions: conditions())
        XCTAssertEqual(forward, .probe("AB0VZ"))
        XCTAssertEqual(forward, reversed)
    }

    func testAStationInsideItsCooldownIsNotDue() {
        let s = settings { $0.stationCooldownMinutes = 60 }
        let histories = ["K0NTS-10": PingPolicy.History(
            lastProbed: noon.addingTimeInterval(-600))]
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-10")], histories: histories,
                              settings: s, conditions: conditions()),
            .hold("nothing is due"))
    }

    // MARK: - Backoff

    /// Being ignored costs progressively more; being heard costs nothing.
    // MARK: - One box, one probe

    /// Field capture 2026-09-03: K0NTS-1, -7, -10 and -14 all came due at
    /// once and went out back to back at the channel spacing — four
    /// transmissions in eight minutes asking one radio the same question.
    /// The per-address cooldown cannot see that they are one box.
    func testASiblingSSIDIsNotProbedRightAfterItsBox() {
        let s = settings { $0.boxCooldownMinutes = 60 }
        let histories = ["K0NTS-10": PingPolicy.History(
            lastProbed: noon.addingTimeInterval(-150))]
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-1")], histories: histories,
                              settings: s, conditions: conditions()),
            .hold("nothing is due"))
    }

    func testTheBoxComesDueAgainWhenItsCooldownIsSpent() {
        let s = settings { $0.boxCooldownMinutes = 60 }
        let histories = ["K0NTS-10": PingPolicy.History(
            lastProbed: noon.addingTimeInterval(-61 * 60))]
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-1")], histories: histories,
                              settings: s, conditions: conditions()),
            .probe("K0NTS-1"))
    }

    /// The rule is about one box, not about everybody. A probe of K0NTS
    /// must not hold up KB5YZB.
    func testAnotherStationIsUnaffectedByTheBoxRule() {
        let s = settings { $0.boxCooldownMinutes = 60 }
        let histories = ["K0NTS-10": PingPolicy.History(
            lastProbed: noon.addingTimeInterval(-150))]
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("KB5YZB-7")], histories: histories,
                              settings: s, conditions: conditions()),
            .probe("KB5YZB-7"))
    }

    /// Zero is the off switch, and off means the addresses are paced on
    /// their own the way they were before this rule existed.
    func testZeroTurnsTheBoxRuleOff() {
        let s = settings { $0.boxCooldownMinutes = 0 }
        let histories = ["K0NTS-10": PingPolicy.History(
            lastProbed: noon.addingTimeInterval(-150))]
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-1")], histories: histories,
                              settings: s, conditions: conditions()),
            .probe("K0NTS-1"))
    }

    /// The bare callsign is one of the box's addresses too — DRLNOD's node
    /// link addresses bare KB5YZB while KB5YZB-7 is the voice that answers.
    func testTheBareCallsignSharesTheBoxWithItsSSIDs() {
        let s = settings { $0.boxCooldownMinutes = 60 }
        let histories = ["KB5YZB": PingPolicy.History(
            lastProbed: noon.addingTimeInterval(-60))]
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("KB5YZB-1")], histories: histories,
                              settings: s, conditions: conditions()),
            .hold("nothing is due"))
    }

    /// A box is held by whichever of its addresses was probed *last*, not
    /// by whichever the dictionary happens to yield first.
    func testTheBoxIsHeldByItsMostRecentProbe() {
        let latest = PingPolicy.lastProbedByBase([
            "K0NTS-1": PingPolicy.History(lastProbed: noon.addingTimeInterval(-3600)),
            "K0NTS-7": PingPolicy.History(lastProbed: noon.addingTimeInterval(-60)),
            "K0NTS-14": PingPolicy.History(lastProbed: noon.addingTimeInterval(-1800)),
            "KB5YZB-7": PingPolicy.History(lastProbed: nil)])
        XCTAssertEqual(latest["K0NTS"], noon.addingTimeInterval(-60))
        XCTAssertNil(latest["KB5YZB"], "never probed holds nobody up")
    }

    /// The box floor does not double on silence — the per-address backoff
    /// is the part that responds to evidence. A box asked an hour ago is
    /// due again whether or not it answered.
    func testTheBoxFloorDoesNotBackOff() {
        let s = settings { $0.boxCooldownMinutes = 60; $0.stationCooldownMinutes = 10 }
        let histories = [
            "K0NTS-10": PingPolicy.History(lastProbed: noon.addingTimeInterval(-61 * 60),
                                           consecutiveSilences: 8)]
        XCTAssertEqual(
            PingPolicy.decide(candidates: [candidate("K0NTS-1")], histories: histories,
                              settings: s, conditions: conditions()),
            .probe("K0NTS-1"),
            "K0NTS-1 has never been probed; its sibling's backoff is not its own")
    }

    func testSilenceDoublesTheWait() {
        let s = settings { $0.stationCooldownMinutes = 60 }
        XCTAssertEqual(PingPolicy.backoff(for: nil, settings: s), 3600)
        XCTAssertEqual(
            PingPolicy.backoff(for: .init(consecutiveSilences: 1), settings: s), 7200)
        XCTAssertEqual(
            PingPolicy.backoff(for: .init(consecutiveSilences: 3), settings: s), 28800)
    }

    func testBackoffIsCappedSoAStationCanComeBack() {
        let s = settings { $0.stationCooldownMinutes = 60 }
        XCTAssertEqual(
            PingPolicy.backoff(for: .init(consecutiveSilences: 99), settings: s),
            PingPolicy.maxBackoff)
    }

    func testAnAnsweredProbeReturnsToThePlainCooldown() {
        let s = settings { $0.stationCooldownMinutes = 30 }
        let answered = PingPolicy.History(
            lastProbed: noon.addingTimeInterval(-3600),
            lastAnswered: noon.addingTimeInterval(-3600),
            consecutiveSilences: 0)
        XCTAssertEqual(PingPolicy.backoff(for: answered, settings: s), 1800)
    }

    // MARK: - Window arithmetic

    func testWindowWrapsOverMidnight() {
        let s = settings { $0.windowStartHour = 22; $0.windowEndHour = 6 }
        let cal = Calendar.current
        func at(_ hour: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: hour))!
        }
        XCTAssertTrue(PingPolicy.isWithinWindow(at(23), settings: s))
        XCTAssertTrue(PingPolicy.isWithinWindow(at(2), settings: s))
        XCTAssertFalse(PingPolicy.isWithinWindow(at(12), settings: s))
        XCTAssertFalse(PingPolicy.isWithinWindow(at(6), settings: s))
    }

    /// A zero-length window would otherwise be the one setting that turns
    /// the feature off without saying so.
    func testEqualHoursMeansAnyHour() {
        let s = settings { $0.windowStartHour = 0; $0.windowEndHour = 0 }
        XCTAssertTrue(PingPolicy.isWithinWindow(noon, settings: s))
    }
}
