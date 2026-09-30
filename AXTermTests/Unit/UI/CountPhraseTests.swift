import XCTest
@testable import AXTerm

/// Counters say "1 message", never "1 messages".
final class CountPhraseTests: XCTestCase {
    func testOneIsSingularAndEverythingElsePlural() {
        XCTAssertEqual(CountPhrase.of(1, "message"), "1 message")
        XCTAssertEqual(CountPhrase.of(0, "message"), "0 messages")
        XCTAssertEqual(CountPhrase.of(70, "message"), "70 messages")
        XCTAssertEqual(CountPhrase.of(2, "hop"), "2 hops")
        XCTAssertEqual(CountPhrase.of(3, "gateway"), "3 gateways")
    }

    func testAnIrregularPlural() {
        XCTAssertEqual(CountPhrase.of(2, "copy", plural: "copies"), "2 copies")
        XCTAssertEqual(CountPhrase.noun(for: 1, "copy", plural: "copies"), "copy")
    }
}
