import XCTest
@testable import AXTerm

/// What the adaptive tuner is allowed to learn from what.
///
/// The parameters it tunes — paclen, window, N2 — are properties of a
/// *channel*. Two radios are two channels: a busy 1200-baud VHF frequency and
/// a clean 9600-baud UHF link have nothing to teach each other, and blending
/// them makes the good one carry the bad one's losses. Until this existed,
/// AXTerm kept one adaptive state for the whole application.
///
/// Timing is different again. RTO comes from SRTT, and SRTT includes the far
/// end's own turnaround — so it belongs to a *route*, not to a radio. Hence
/// two scopes rather than one, and a fallback chain between them.
final class AdaptiveScopeTests: XCTestCase {

    private let vhf = RadioID(rawValue: "vhf")
    private let uhf = RadioID(rawValue: "uhf")

    // MARK: - Identity

    /// The bug this exists to prevent: the same destination over the same path
    /// on two different radios is two different things.
    func testTheSameRouteOnTwoRadiosIsTwoScopes() {
        let a = AdaptiveScope.route(radio: vhf, destination: "W0ARP-10", path: "")
        let b = AdaptiveScope.route(radio: uhf, destination: "W0ARP-10", path: "")
        XCTAssertNotEqual(a, b)
    }

    /// Callsigns and paths arrive from a session, from the compose field and
    /// from a saved profile, in whatever case the operator typed. One route
    /// must not become three entries that each learn a third as fast.
    func testACallsignIsTheSameRouteHoweverItWasTyped() {
        XCTAssertEqual(AdaptiveScope.route(radio: vhf, destination: "w0arp-10", path: "drlnod"),
                       AdaptiveScope.route(radio: vhf, destination: "W0ARP-10", path: "DRLNOD"))
        XCTAssertEqual(AdaptiveScope.route(radio: vhf, destination: " W0ARP-10 ", path: " "),
                       AdaptiveScope.route(radio: vhf, destination: "W0ARP-10", path: ""))
    }

    /// A path is an ordered list of hops. Reversing it is a different path and
    /// must not share a key.
    func testPathOrderMatters() {
        XCTAssertNotEqual(AdaptiveScope.route(radio: vhf, destination: "A", path: "X,Y"),
                          AdaptiveScope.route(radio: vhf, destination: "A", path: "Y,X"))
    }

    // MARK: - The fallback chain

    /// A route knows least and falls back to its channel; a channel falls back
    /// to the operator's configured baseline, which is the end of the line.
    func testARouteFallsBackToItsRadioAndNoFurther() {
        let route = AdaptiveScope.route(radio: vhf, destination: "W0ARP-10", path: "")
        XCTAssertEqual(route.fallback, .radio(vhf))
        XCTAssertNil(AdaptiveScope.radio(vhf).fallback)
    }

    /// Every scope names exactly one radio, so a sample can never be filed
    /// against the wrong channel.
    func testEveryScopeNamesItsRadio() {
        XCTAssertEqual(AdaptiveScope.route(radio: uhf, destination: "A", path: "").radio, uhf)
        XCTAssertEqual(AdaptiveScope.radio(uhf).radio, uhf)
    }

    /// One sample teaches both the route and the channel it rode on. The
    /// channel figure is the aggregate of everything crossing that radio, and
    /// it is what a brand-new route will inherit.
    func testASampleTeachesTheRouteAndTheChannel() {
        let route = AdaptiveScope.route(radio: vhf, destination: "W0ARP-10", path: "DRLNOD")
        XCTAssertEqual(route.scopesToTeach, [route, .radio(vhf)])
        XCTAssertEqual(AdaptiveScope.radio(vhf).scopesToTeach, [.radio(vhf)])
    }

    // MARK: - What to use, versus what to believe

    /// For *choosing configuration*, a route we know nothing about inherits
    /// its channel: it is the best answer available, and being wrong costs one
    /// session's opening parameters.
    func testAnUnknownRouteUsesWhatItsChannelKnows() {
        var learned = TxAdaptiveSettings()
        learned.paclen.currentAdaptive = 64
        let store: [AdaptiveScope: TxAdaptiveSettings] = [.radio(vhf): learned]

        let resolved = AdaptiveScope.resolve(.route(radio: vhf, destination: "N0CALL", path: ""),
                                             in: store, baseline: TxAdaptiveSettings())
        XCTAssertEqual(resolved.paclen.currentAdaptive, 64)
    }

    /// A route we *have* learned about answers for itself, whatever the
    /// channel around it is doing.
    func testAKnownRouteAnswersForItself() {
        var channel = TxAdaptiveSettings(); channel.paclen.currentAdaptive = 64
        var route = TxAdaptiveSettings(); route.paclen.currentAdaptive = 200
        let scope = AdaptiveScope.route(radio: vhf, destination: "N0CALL", path: "")
        let resolved = AdaptiveScope.resolve(scope,
                                             in: [.radio(vhf): channel, scope: route],
                                             baseline: TxAdaptiveSettings())
        XCTAssertEqual(resolved.paclen.currentAdaptive, 200)
    }

    /// A channel nobody has used starts from the operator's baseline.
    func testAnUnknownChannelUsesTheOperatorsBaseline() {
        var baseline = TxAdaptiveSettings()
        baseline.paclen.currentAdaptive = 200
        XCTAssertEqual(AdaptiveScope.resolve(.radio(uhf), in: [:], baseline: baseline)
                        .paclen.currentAdaptive, 200)
    }

    /// And never another radio's experience, at any point in the chain.
    func testTheChainNeverCrossesToAnotherRadio() {
        var other = TxAdaptiveSettings(); other.paclen.currentAdaptive = 64
        var baseline = TxAdaptiveSettings(); baseline.paclen.currentAdaptive = 200
        let resolved = AdaptiveScope.resolve(.route(radio: uhf, destination: "X", path: ""),
                                             in: [.radio(vhf): other], baseline: baseline)
        XCTAssertEqual(resolved.paclen.currentAdaptive, 200,
                       "the VHF radio's experience is not evidence about UHF")
    }

    // MARK: - Saying which

    /// The operator has to be able to tell which channel a figure came from,
    /// or a per-radio number is worse than a global one.
    func testAScopeCanNameItselfForTheOperator() {
        let names = [vhf: "2 m", uhf: "70 cm"]
        XCTAssertEqual(AdaptiveScope.radio(vhf).label { names[$0] }, "2 m")
        XCTAssertEqual(AdaptiveScope.route(radio: uhf, destination: "W0ARP-10", path: "DRLNOD")
                        .label { names[$0] },
                       "W0ARP-10 via DRLNOD on 70 cm")
        XCTAssertEqual(AdaptiveScope.route(radio: vhf, destination: "W0ARP-10", path: "")
                        .label { names[$0] },
                       "W0ARP-10 direct on 2 m")
        XCTAssertEqual(AdaptiveScope.radio(vhf).label { _ in nil }, "vhf")
    }
}
