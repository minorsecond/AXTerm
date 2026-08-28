import XCTest
@testable import AXTerm

/// The White Pages merge rule.
///
/// The rule exists because a directory mixes two kinds of fact — what an
/// operator told you and what you worked out from their traffic — and the
/// obvious implementation, last-writer-wins, quietly destroys the first with
/// the second. Every case here is about keeping testimony above inference.
final class BBSWhitePagesTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func field(_ value: String,
                       _ source: WhitePagesEntry.Source,
                       at seconds: TimeInterval) -> WhitePagesEntry.Field {
        WhitePagesEntry.Field(value: value, source: source, updatedAt: t(seconds))
    }

    // MARK: - The rule

    func testAnythingBeatsNothing() {
        XCTAssertTrue(WhitePagesEntry.replaces(field("Bob", .observed, at: 0), existing: nil))
    }

    func testStrongerProvenanceWinsEvenWhenOlder() {
        XCTAssertTrue(WhitePagesEntry.replaces(
            field("Bob", .selfReported, at: 0),
            existing: field("ROBERT", .observed, at: 9_000)))
    }

    /// The case the rule is for: a guess made this morning must not overwrite
    /// something the operator typed last year.
    func testWeakerProvenanceLosesEvenWhenNewer() {
        XCTAssertFalse(WhitePagesEntry.replaces(
            field("ROBERT", .observed, at: 9_000),
            existing: field("Bob", .selfReported, at: 0)))
    }

    func testEqualProvenanceTakesTheNewerValue() {
        XCTAssertTrue(WhitePagesEntry.replaces(
            field("Bobby", .selfReported, at: 100),
            existing: field("Bob", .selfReported, at: 0)))
    }

    func testEqualProvenanceKeepsTheNewerValueAgainstAnOlderOne() {
        XCTAssertFalse(WhitePagesEntry.replaces(
            field("Bob", .selfReported, at: 0),
            existing: field("Bobby", .selfReported, at: 100)))
    }

    func testMessageDerivedBeatsObserved() {
        XCTAssertTrue(WhitePagesEntry.replaces(
            field("K0NTS", .fromMessage, at: 0),
            existing: field("W0ARP", .observed, at: 500)))
    }

    // MARK: - Learning

    func testLearnStoresAndTrims() {
        var entry = WhitePagesEntry(callsign: "w0arp")
        XCTAssertTrue(entry.learn(.name, value: "  Bob  ", source: .selfReported, at: t(0)))
        XCTAssertEqual(entry.callsign, "W0ARP")
        XCTAssertEqual(entry.value(.name), "Bob")
    }

    func testLearnReportsWhenNothingChanged() {
        var entry = WhitePagesEntry(callsign: "W0ARP")
        entry.learn(.name, value: "Bob", source: .selfReported, at: t(100))
        XCTAssertFalse(entry.learn(.name, value: "Robert", source: .observed, at: t(200)),
                       "inference must not overwrite testimony")
        XCTAssertEqual(entry.value(.name), "Bob")
    }

    /// An operator can retract what they said. Inference falling silent must
    /// not delete it for them.
    func testOnlyTheOperatorCanClearAField() {
        var entry = WhitePagesEntry(callsign: "W0ARP")
        entry.learn(.qth, value: "Denver", source: .selfReported, at: t(0))

        XCTAssertFalse(entry.learn(.qth, value: "", source: .observed, at: t(100)))
        XCTAssertEqual(entry.value(.qth), "Denver")

        XCTAssertTrue(entry.learn(.qth, value: "", source: .selfReported, at: t(200)))
        XCTAssertNil(entry.value(.qth))
    }

    func testLastUpdatedIsTheNewestField() {
        var entry = WhitePagesEntry(callsign: "W0ARP")
        entry.learn(.name, value: "Bob", source: .selfReported, at: t(0))
        entry.learn(.qth, value: "Denver", source: .selfReported, at: t(500))
        XCTAssertEqual(entry.lastUpdated, t(500))
    }

    // MARK: - Licence records

    private func licence(name: String? = nil,
                         locality: String? = nil,
                         state: String? = nil) -> CallsignRecord {
        CallsignRecord(callsign: "W0ARP", name: name, locality: locality,
                       state: state, source: "test", fetchedAt: t(0))
    }

    /// Only the two fields a licence actually answers. Filling a home BBS or a
    /// postcode from here would put something weakly related in a field people
    /// read as fact.
    func testLicenceContributesNameAndLocationOnly() {
        let fields = WhitePagesEntry.fields(
            from: licence(name: "Robert Wardrup", locality: "Denver", state: "CO"))
        XCTAssertEqual(fields.map(\.0), [.name, .qth])
        XCTAssertEqual(fields.first(where: { $0.0 == .qth })?.1, "Denver, CO")
    }

    /// A locality with no state is ambiguous across the country; a state alone
    /// says nothing the callsign prefix did not.
    func testLocationNeedsWhicheverHalvesExist() {
        XCTAssertEqual(WhitePagesEntry.fields(from: licence(locality: "Denver"))
            .first?.1, "Denver")
        XCTAssertEqual(WhitePagesEntry.fields(from: licence(state: "CO"))
            .first?.1, "CO")
        XCTAssertTrue(WhitePagesEntry.fields(from: licence()).isEmpty)
    }

    func testLicenceFillsWhatIsMissing() {
        var entry = WhitePagesEntry(callsign: "W0ARP")
        XCTAssertTrue(entry.learn(from: licence(name: "Robert", locality: "Denver",
                                                state: "CO"), at: t(0)))
        XCTAssertEqual(entry.value(.name), "Robert")
        XCTAssertEqual(entry.fields[.name]?.source, .licenceRecord)
    }

    /// The point of ranking it below testimony: someone who said to call them
    /// Bob is not renamed to their licence name at the next lookup.
    func testLicenceNeverOverwritesWhatTheOperatorWasTold() {
        var entry = WhitePagesEntry(callsign: "W0ARP")
        entry.learn(.name, value: "Bob", source: .selfReported, at: t(0))
        XCTAssertFalse(entry.learn(from: licence(name: "Robert J Wardrup"), at: t(9_000)))
        XCTAssertEqual(entry.value(.name), "Bob")
    }

    /// And the point of ranking it above inference.
    func testLicenceImprovesAGuess() {
        var entry = WhitePagesEntry(callsign: "W0ARP")
        entry.learn(.qth, value: "somewhere", source: .observed, at: t(9_000))
        XCTAssertTrue(entry.learn(from: licence(locality: "Denver", state: "CO"), at: t(0)))
        XCTAssertEqual(entry.value(.qth), "Denver, CO")
    }

    // MARK: - Reporting

    /// A caller reading their own entry should be able to see which parts were
    /// guessed, so they can correct them.
    func testReportMarksInferredFieldsAndLeavesTestimonyPlain() {
        var entry = WhitePagesEntry(callsign: "W0ARP")
        entry.learn(.name, value: "Bob", source: .selfReported, at: t(0))
        entry.learn(.homeBBS, value: "K0NTS", source: .fromMessage, at: t(0))

        let report = entry.report()
        let name = try! XCTUnwrap(report.first { $0.contains("Name") })
        let bbs = try! XCTUnwrap(report.first { $0.contains("Home BBS") })

        XCTAssertFalse(name.contains("("), "testimony needs no qualifier: \(name)")
        XCTAssertTrue(bbs.contains("taken from a message"), bbs)
    }

    func testEmptyEntryReportsThatItIsEmpty() {
        XCTAssertEqual(WhitePagesEntry(callsign: "W0ARP").report(),
                       ["Nothing on file for W0ARP."])
    }

    func testProvenanceRanksAreOrdered() {
        let order: [WhitePagesEntry.Source] = [.observed, .fromMessage,
                                               .licenceRecord, .selfReported]
        XCTAssertEqual(order.map(\.rank), order.map(\.rank).sorted())
        XCTAssertEqual(Set(order), Set(WhitePagesEntry.Source.allCases),
                       "a new source must be placed in the ordering deliberately")
    }
}
