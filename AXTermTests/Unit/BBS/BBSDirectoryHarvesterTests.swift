import XCTest
@testable import AXTerm

/// Reading white pages facts out of another BBS's output.
///
/// Weighted toward *not* finding things. Every candidate here is a claim about
/// a real person, and a parser that guesses widely fills a directory with
/// confident nonsense — which is worse than an empty one, because nobody
/// checks a field that looks filled in.
final class BBSDirectoryHarvesterTests: XCTestCase {

    private func candidates(_ lines: [String]) -> [BBSDirectoryHarvester.Candidate] {
        BBSDirectoryHarvester.candidates(in: lines)
    }

    // MARK: - CALL @ BBS

    /// The FBB convention, and the highest-yield thing in a session: one
    /// message listing names a dozen operators' home BBS.
    func testHomeBBSFromAListing() {
        let found = candidates([
            "26543 P   1234 K0EPI  @K0NTS W0ARP  260826 Antenna party"
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].callsign, "K0EPI")
        XCTAssertEqual(found[0].key, .homeBBS)
        XCTAssertEqual(found[0].value, "K0NTS")
    }

    /// Adjacency is the whole signal, so spacing must not matter.
    func testSpacingAroundTheAtSignIsIrrelevant() {
        for line in ["K0EPI@K0NTS", "K0EPI @K0NTS", "K0EPI @ K0NTS", "K0EPI  @  K0NTS"] {
            XCTAssertEqual(candidates([line]).first?.value, "K0NTS", line)
        }
    }

    func testSSIDsAreStrippedFromTheSubject() {
        XCTAssertEqual(candidates(["K0EPI-7 @ K0NTS"]).first?.callsign, "K0EPI")
    }

    func testEmailAddressesAreNotHomeBBSDeclarations() {
        XCTAssertTrue(candidates(["From: bob@example.com"]).isEmpty)
        XCTAssertTrue(candidates(["reply to someone@gmail.com please"]).isEmpty)
    }

    func testAStationIsNotItsOwnHomeBBS() {
        XCTAssertTrue(candidates(["K0EPI @ K0EPI"]).isEmpty)
    }

    func testNonCallsignsAreIgnored() {
        XCTAssertTrue(candidates(["meeting @ noon", "TO @ ALL", "see @ the tower"]).isEmpty)
    }

    // MARK: - Hierarchical addresses

    /// The real reply from KB5YZB-7 to `I KB5YZB`, which the first version of
    /// this parser ignored entirely.
    func testHierarchicalAddressFromAnInfoReply() {
        let found = candidates(["KB5YZB  KB5YZB.#NCO.CO.USA.NOAM"])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].callsign, "KB5YZB")
        XCTAssertEqual(found[0].key, .homeBBS)
        // Kept whole: this is what goes after the `@` to route mail there.
        // Splitting out "CO" would trade the useful string for a worse one.
        XCTAssertEqual(found[0].value, "KB5YZB.#NCO.CO.USA.NOAM")
    }

    func testHierarchicalAddressAfterAnAtSign() {
        XCTAssertEqual(candidates(["26543 P 1234 K0EPI @K0NTS.#NCO.CO.USA.NOAM W0ARP"])
            .first?.value, "K0NTS.#NCO.CO.USA.NOAM")
    }

    func testShorterHierarchiesAreAccepted() {
        XCTAssertEqual(BBSDirectoryHarvester.hierarchicalAddress("K0NTS.CO.USA"),
                       "K0NTS.CO.USA")
        XCTAssertEqual(BBSDirectoryHarvester.hierarchicalAddress("K0NTS.USA"), "K0NTS.USA")
    }

    /// Anchored on the first component being a callsign, which is what keeps a
    /// domain name or a sentence with a full stop from qualifying.
    func testDomainNamesAndProseAreNotHierarchicalAddresses() {
        for token in ["example.com", "winlink.org", "sentence.Next", "K0NTS.",
                      "..", "K0NTS.this-has-a-dash"] {
            XCTAssertNil(BBSDirectoryHarvester.hierarchicalAddress(token), token)
        }
        XCTAssertTrue(candidates(["Please see winlink.org for details"]).isEmpty)
    }

    /// The line has to start with the callsign the record is about; a stray
    /// address in prose belongs to nobody in particular.
    func testHierarchyNeedsASubjectAtTheStartOfTheLine() {
        XCTAssertTrue(candidates(["forwarded via KB5YZB.#NCO.CO.USA.NOAM"]).isEmpty)
    }

    // MARK: - Labelled records

    func testLabelledRecordUnderASubject() {
        let found = candidates([
            "White pages: W0ARP",
            "  Name: Bob",
            "  Location: Denver, CO",
            "  Postcode: 80202"
        ])
        XCTAssertEqual(Set(found.map(\.key)), [.name, .qth, .zip])
        XCTAssertTrue(found.allSatisfy { $0.callsign == "W0ARP" })
        XCTAssertEqual(found.first(where: { $0.key == .name })?.value, "Bob")
    }

    func testABareCallsignLineIntroducesARecord() {
        let found = candidates(["W0ARP", "Name : Bob"])
        XCTAssertEqual(found.first?.callsign, "W0ARP")
        XCTAssertEqual(found.first?.value, "Bob")
    }

    /// Without a subject there is nobody to attribute the fact to, and
    /// guessing would attach somebody's name to the wrong callsign.
    func testLabelsWithNoSubjectAreIgnored() {
        XCTAssertTrue(candidates(["Name: Bob", "QTH: Denver"]).isEmpty)
    }

    func testUnknownLabelsAreIgnored() {
        XCTAssertTrue(candidates(["W0ARP", "Favourite rig: FT-991A"]).isEmpty)
    }

    /// A home BBS is a callsign. Anything else in that field is a parse gone
    /// wrong, and one wrong fact discredits the several it arrived with.
    func testAHomeBBSThatIsNotACallsignIsRejected() {
        XCTAssertTrue(candidates(["W0ARP", "Home BBS: not sure"]).isEmpty)
        XCTAssertEqual(candidates(["W0ARP", "Home BBS: K0NTS"]).first?.value, "K0NTS")
    }

    func testAbsurdlyLongValuesAreIgnored() {
        XCTAssertTrue(candidates(["W0ARP", "Name: " + String(repeating: "x", count: 200)])
            .isEmpty)
    }

    // MARK: - Housekeeping

    func testTheSameFactTwiceIsOneCandidate() {
        XCTAssertEqual(candidates(["K0EPI @ K0NTS", "K0EPI @ K0NTS"]).count, 1)
    }

    func testEvidenceIsCarriedSoTheOperatorCanJudge() {
        let line = "26543 P   1234 K0EPI  @K0NTS W0ARP  260826 Antenna party"
        XCTAssertEqual(candidates([line]).first?.evidence, line.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Callsign recognition

    func testCallsignRecognition() {
        for good in ["K0EPI", "W0ARP", "KB5YZB", "K0EPI-7", "N0CVL-10", "M0ABC"] {
            XCTAssertTrue(BBSDirectoryHarvester.isCallsign(good), good)
        }
        for bad in ["ALL", "MAIL", "NODES", "K0EPI-99", "HELLO", "12345", "A1", "K0EP1"] {
            XCTAssertFalse(BBSDirectoryHarvester.isCallsign(bad), bad)
        }
    }
}
