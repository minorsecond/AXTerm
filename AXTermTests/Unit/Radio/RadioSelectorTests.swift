import XCTest
@testable import AXTerm

/// Which radio a connect left on Auto goes out on, and the sentence that
/// says why. The sentences are pinned because the connect bar shows them
/// verbatim and a log reader must be able to trust them.
final class RadioSelectorTests: XCTestCase {

    private let base = RadioID.primary
    private let uhf = RadioID(rawValue: "uhf")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func radio(_ id: RadioID, _ name: String, connected: Bool = true,
                       heardAgo: TimeInterval? = nil, etx: Double? = nil,
                       ttl: TimeInterval = 3600) -> RadioSelector.Evidence {
        RadioSelector.Evidence(radio: id, name: name, connected: connected,
                               lastHeard: heardAgo.map { now.addingTimeInterval(-$0) },
                               etx: etx, ttl: ttl)
    }

    private func choose(_ radios: [RadioSelector.Evidence], route: RadioID? = nil) -> RadioSelector.Choice? {
        RadioSelector.choose(firstHop: "K0NTS-1", radios: radios, routeRadio: route, now: now)
    }

    func testOneRadioIsTheAnswerWhateverItKnows() {
        let choice = choose([radio(base, "Base", connected: false)])
        XCTAssertEqual(choice?.radio, base)
        XCTAssertEqual(choice?.reason, .onlyRadio)
        XCTAssertEqual(choice?.explanation, "Auto → Base: the only radio.")
    }

    func testNoRadiosIsNoAnswer() {
        XCTAssertNil(choose([]))
    }

    /// Fresh evidence wins, best ETX first, and the sentence accounts for
    /// every radio that was not chosen.
    func testFreshEvidenceWithTheBestETXWins() {
        let choice = choose([
            radio(base, "Base", heardAgo: 3 * 3600, etx: 1.1),
            radio(uhf, "IC-705", heardAgo: 4 * 60, etx: 1.2),
        ])
        XCTAssertEqual(choice?.radio, uhf)
        XCTAssertEqual(choice?.reason, .freshEvidence)
        XCTAssertEqual(choice?.explanation,
                       "Auto → IC-705: heard K0NTS-1 there 4 min ago, ETX 1.2. Base last heard it 3 h ago, past its TTL.")
    }

    func testAmongFreshRadiosTheLowerETXWins() {
        let choice = choose([
            radio(base, "Base", heardAgo: 10 * 60, etx: 2.4),
            radio(uhf, "IC-705", heardAgo: 20 * 60, etx: 1.3),
        ])
        XCTAssertEqual(choice?.radio, uhf)
        XCTAssertEqual(choice?.explanation,
                       "Auto → IC-705: heard K0NTS-1 there 20 min ago, ETX 1.3. Base heard it 10 min ago, ETX 2.4.")
    }

    /// Two ETX readings within the tolerance are the same reading; the
    /// more recent hearing decides.
    func testEqualETXFallsToRecency() {
        let choice = choose([
            radio(base, "Base", heardAgo: 30 * 60, etx: 1.20),
            radio(uhf, "IC-705", heardAgo: 2 * 60, etx: 1.23),
        ])
        XCTAssertEqual(choice?.radio, uhf)
    }

    /// Identical evidence falls to the operator's order, so the same inputs
    /// always pick the same radio.
    func testATieFallsToTheOperatorsOrder() {
        let choice = choose([
            radio(base, "Base", heardAgo: 60, etx: 1.0),
            radio(uhf, "IC-705", heardAgo: 60, etx: 1.0),
        ])
        XCTAssertEqual(choice?.radio, base)
    }

    /// A fresh hearing with no link statistics yet still beats a stale one,
    /// and sorts behind every measured fresh link.
    func testAnUnmeasuredFreshLinkBeatsAStaleOneAndLosesToAMeasuredOne() {
        XCTAssertEqual(choose([
            radio(base, "Base", heardAgo: 5 * 3600, etx: 1.0),
            radio(uhf, "IC-705", heardAgo: 60),
        ])?.radio, uhf)
        let measured = choose([
            radio(base, "Base", heardAgo: 50 * 60, etx: 3.0),
            radio(uhf, "IC-705", heardAgo: 60),
        ])
        XCTAssertEqual(measured?.radio, base)
        XCTAssertEqual(measured?.explanation,
                       "Auto → Base: heard K0NTS-1 there 50 min ago, ETX 3.0. IC-705 heard it 1 min ago, link unmeasured.")
    }

    func testADisconnectedRadioIsNeverChosenAndIsSaidToBeDisconnected() {
        let choice = choose([
            radio(base, "Base", connected: false, heardAgo: 60, etx: 1.0),
            radio(uhf, "IC-705", heardAgo: 3 * 60, etx: 1.5),
        ])
        XCTAssertEqual(choice?.radio, uhf)
        XCTAssertEqual(choice?.explanation,
                       "Auto → IC-705: heard K0NTS-1 there 3 min ago, ETX 1.5. Base is not connected.")
    }

    func testWithoutFreshEvidenceTheMostRecentHearingWins() {
        let choice = choose([
            radio(base, "Base", heardAgo: 5 * 3600),
            radio(uhf, "IC-705", heardAgo: 2 * 3600),
        ])
        XCTAssertEqual(choice?.radio, uhf)
        XCTAssertEqual(choice?.reason, .mostRecentlyHeard)
        XCTAssertEqual(choice?.explanation,
                       "Auto → IC-705: heard K0NTS-1 there 2 h ago, past its TTL but the most recent of any radio.")
    }

    func testANetRomRouteDecidesWhenNothingWasHeardDirectly() {
        let choice = choose([radio(base, "Base"), radio(uhf, "IC-705")], route: uhf)
        XCTAssertEqual(choice?.radio, uhf)
        XCTAssertEqual(choice?.reason, .netRomRoute)
        XCTAssertEqual(choice?.explanation,
                       "Auto → IC-705: no radio has heard K0NTS-1 directly; a NET/ROM route to it was learned there.")
    }

    func testWithNoEvidenceTheFirstConnectedRadioIsChosen() {
        let choice = choose([radio(base, "Base", connected: false), radio(uhf, "IC-705")])
        XCTAssertEqual(choice?.radio, uhf)
        XCTAssertEqual(choice?.reason, .firstInList)
        XCTAssertEqual(choice?.explanation,
                       "Auto → IC-705: no radio has heard K0NTS-1; IC-705 is first in the radio list.")
    }

    func testNothingConnectedNamesTheFirstRadioAndSaysSo() {
        let choice = choose([radio(base, "Base", connected: false), radio(uhf, "IC-705", connected: false)])
        XCTAssertEqual(choice?.radio, base)
        XCTAssertEqual(choice?.reason, .nothingConnected)
        XCTAssertEqual(choice?.explanation, "Auto → Base: no radio is connected.")
    }

    /// The TTL is the link's own, not a constant: a chatty link's hearing
    /// goes stale sooner.
    func testFreshnessUsesTheLinksOwnTTL() {
        let choice = choose([
            radio(base, "Base", heardAgo: 10 * 60, etx: 1.0, ttl: 5 * 60),
            radio(uhf, "IC-705", heardAgo: 30 * 60, etx: 2.0, ttl: 3600),
        ])
        XCTAssertEqual(choice?.radio, uhf, "Base's hearing is past its five-minute TTL")
    }

    func testAgoIsCoarseAndLocaleFree() {
        XCTAssertEqual(RadioSelector.ago(30), "just now")
        XCTAssertEqual(RadioSelector.ago(4 * 60 + 59), "4 min ago")
        XCTAssertEqual(RadioSelector.ago(3 * 3600 + 100), "3 h ago")
        XCTAssertEqual(RadioSelector.ago(2 * 86_400), "2 d ago")
    }
}
