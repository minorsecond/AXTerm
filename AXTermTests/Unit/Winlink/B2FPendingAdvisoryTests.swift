import XCTest
@testable import AXTerm

final class B2FPendingAdvisoryTests: XCTestCase {

    /// Verbatim off the air, 2026-08-30: a CMS session monitored via
    /// W0ARP-10. The subject runs to the end of the line and contains
    /// spaces, parentheses and a comma.
    func testParsesACapturedCMSAdvisory() throws {
        let advisory = try XCTUnwrap(B2FPendingAdvisory.parse(
            ";PM: WN6OTL JDMCZA45WR5W 1048 KN4LQN@winlink.org Winlink Wednesday Roster Published (26 August 2026, Episode #520)"))

        XCTAssertEqual(advisory.destination, "WN6OTL")
        XCTAssertEqual(advisory.mid, "JDMCZA45WR5W")
        XCTAssertEqual(advisory.size, 1048)
        XCTAssertEqual(advisory.origin, "KN4LQN@winlink.org")
        XCTAssertEqual(advisory.subject,
                       "Winlink Wednesday Roster Published (26 August 2026, Episode #520)")
    }

    /// The advertised size is the *compressed* one: the same capture's
    /// proposal for PJ0TA9P71Q1T read `FC EM PJ0TA9P71Q1T 1879 949 0`, and
    /// its advisory said 949 — the wire bytes, not the decoded text.
    func testTheAdvertisedSizeIsTheCompressedSize() throws {
        let advisory = try XCTUnwrap(B2FPendingAdvisory.parse(
            ";PM: WN6OTL PJ0TA9P71Q1T 949 KN4LQN@winlink.org Winlink Wednesday Net Confirmation (Episode #520)"))
        let proposal = try XCTUnwrap(B2FProposal.Proposal.parse("FC EM PJ0TA9P71Q1T 1879 949 0"))

        XCTAssertEqual(advisory.size, proposal.compressedSize)
        XCTAssertNotEqual(advisory.size, proposal.uncompressedSize)
    }

    /// The first field is the destination, not the sender — the reverse of
    /// how the line reads, and the reverse of what this parser first
    /// assumed. Captured 2026-08-31 over W0ARP-10: K0EPI-7 was collecting,
    /// and the message was an inquiry reply the CMS service sent *to* them.
    /// Showing it as "from K0EPI-7 to SERVICE" is how the bug looked.
    func testTheFirstFieldIsTheDestinationNotTheSender() throws {
        let advisory = try XCTUnwrap(B2FPendingAdvisory.parse(
            ";PM: K0EPI-7 J71ZYJ4NZ90C 1309 SERVICE@winlink.org INQUIRY - https://tgftp.nws.noaa.gov/data/raw/fp/fpus65.kbou.sft.co.txt"))

        XCTAssertEqual(advisory.destination, "K0EPI-7")
        XCTAssertEqual(advisory.origin, "SERVICE@winlink.org")
        XCTAssertEqual(advisory.subject,
                       "INQUIRY - https://tgftp.nws.noaa.gov/data/raw/fp/fpus65.kbou.sft.co.txt")
    }

    func testSubjectMayBeAbsent() throws {
        let advisory = try XCTUnwrap(B2FPendingAdvisory.parse(";PM: N0CALL ABCDEFGH1234 512 K0EPI"))
        XCTAssertEqual(advisory.origin, "K0EPI")
        XCTAssertEqual(advisory.subject, "")
    }

    func testToleratesRunsOfSpacesAndACaseVariantPrefix() throws {
        let advisory = try XCTUnwrap(B2FPendingAdvisory.parse(
            ";pm:  N0CALL   ABCDEFGH1234  512  K0EPI   Padded subject"))
        XCTAssertEqual(advisory.destination, "N0CALL")
        XCTAssertEqual(advisory.size, 512)
        XCTAssertEqual(advisory.subject, "Padded subject")
    }

    /// Anything unparseable must be nil rather than a half-filled record:
    /// a wrong subject beside a download button is worse than none.
    func testRejectsMalformedLines() {
        XCTAssertNil(B2FPendingAdvisory.parse("FC EM ABCDEFGH1234 100 50 0"))
        XCTAssertNil(B2FPendingAdvisory.parse(";PM: N0CALL ABCDEFGH1234"))
        XCTAssertNil(B2FPendingAdvisory.parse(";PM: N0CALL ABCDEFGH1234 notanumber K0EPI Subject"))
        XCTAssertNil(B2FPendingAdvisory.parse(";PM: N0CALL ABCDEFGH1234 -5 K0EPI Subject"))
        XCTAssertNil(B2FPendingAdvisory.parse(";PR: 29253381"))
    }
}
