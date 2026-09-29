import XCTest
@testable import AXTerm

/// Turning the names operators use into the addresses NET/ROM uses.
///
/// The live example throughout: the node the operator calls **COSCO** is
/// **KE0GB-7** on the air — "Connected to COSCO:KE0GB-7" in the field
/// capture. NET/ROM routes on the callsign; the alias belongs in the
/// alias field, not the address field.
final class NetRomDestinationResolverTests: XCTestCase {

    private let directory: [String: String] = [
        "COSCO": "KE0GB-7",
        "DRLNOD": "KE0NCQ",
        "YZBBPQ": "KB5YZB-7",
        "EVANS": "W0ARP-10"
    ]

    private func resolve(_ name: String,
                         using table: [String: String]? = nil)
    -> NetRomDestinationResolver.Resolution {
        let source = table ?? directory
        return NetRomDestinationResolver.resolve(name) { source[$0.uppercased()] }
    }

    // MARK: - Aliases become callsigns

    func testAliasResolvesToItsCallsign() {
        let resolution = resolve("COSCO")
        XCTAssertEqual(resolution.address, AX25Address(call: "KE0GB", ssid: 7),
                       "the L3 header must carry the callsign")
        XCTAssertEqual(resolution.requestedAlias, "COSCO", "…and remember what was asked for")
        XCTAssertTrue(resolution.didResolve)
    }

    func testResolutionIsCaseAndWhitespaceInsensitive() {
        for spelling in ["cosco", " COSCO ", "Cosco"] {
            XCTAssertEqual(resolve(spelling).address.display, "KE0GB-7", spelling)
        }
    }

    func testAliasWithSSIDResolves() {
        XCTAssertEqual(resolve("YZBBPQ").address.display, "KB5YZB-7")
    }

    // MARK: - Callsigns are left alone

    func testACallsignIsNeverRewritten() {
        let resolution = resolve("KE0GB-7")
        XCTAssertEqual(resolution.address.display, "KE0GB-7")
        XCTAssertNil(resolution.requestedAlias)
        XCTAssertFalse(resolution.didResolve)
    }

    func testACallsignThatAlsoAppearsInTheAliasTableIsNotRewritten() {
        // A directory can contain anything; a real callsign the operator
        // typed must not be swapped out from under them.
        let odd = ["KE0GB-7": "N0XYZ-1"]
        XCTAssertEqual(resolve("KE0GB-7", using: odd).address.display, "KE0GB-7",
                       "a valid callsign is the answer, not a lookup key")
    }

    func testSSIDsAreCarriedThrough() {
        for ssid in 0...15 {
            let call = AX25Address(call: "W0ARP", ssid: ssid).display
            XCTAssertEqual(resolve(call).address.display, call)
        }
    }

    // MARK: - Unknown names pass through

    func testUnknownAliasIsSentAsNamed() {
        // This network really does answer to aliases at layer 2 — DRLNOD
        // accepts a SABM addressed to "DRLNOD". Refusing to transmit
        // would break what works today, so pass it through and report
        // honestly that nothing was resolved.
        let resolution = resolve("MYSTERY", using: [:])
        XCTAssertEqual(resolution.address.display, "MYSTERY")
        XCTAssertFalse(resolution.didResolve)
        XCTAssertNil(resolution.requestedAlias)
    }

    func testAliasMappedToJunkIsNotUsed() {
        // A directory entry that is not a callsign cannot go in the
        // address field; better to send the name as typed than to
        // substitute something equally unroutable.
        let junk = ["COSCO": "NOTACALL"]
        XCTAssertEqual(resolve("COSCO", using: junk).address.display, "COSCO")
        XCTAssertFalse(resolve("COSCO", using: junk).didResolve)
    }

    func testNamesLongerThanSixCharactersCannotBeAddressed() {
        // An AX.25 address field is six characters, which is why NET/ROM
        // aliases are six. A longer name is truncated by the encoder, so
        // resolving one to a real callsign matters more, not less.
        let resolution = resolve("LONGISH", using: ["LONGISH": "KE0GB-7"])
        XCTAssertEqual(resolution.address.display, "KE0GB-7",
                       "resolution rescues a name the address field could not hold")
    }

    func testEmptyMappingIsIgnored() {
        XCTAssertEqual(resolve("COSCO", using: ["COSCO": ""]).address.display, "COSCO")
    }

    // MARK: - Display

    func testDisplayNameKeepsBothNames() {
        XCTAssertEqual(resolve("COSCO").displayName, "COSCO (KE0GB-7)",
                       "the operator asked for COSCO; the air carries KE0GB-7")
        XCTAssertEqual(resolve("KE0GB-7").displayName, "KE0GB-7",
                       "no parenthetical when there is nothing to add")
    }

    // MARK: - Route lookup keys

    func testRouteLookupTriesBothNames() {
        // The route table is keyed by whatever the broadcast said, so a
        // resolved circuit must still find a route learned under the
        // alias.
        let keys = NetRomDestinationResolver.routeLookupKeys(for: resolve("COSCO"))
        XCTAssertEqual(keys, ["KE0GB-7", "COSCO"])
    }

    func testRouteLookupForAPlainCallsignIsJustItself() {
        XCTAssertEqual(
            NetRomDestinationResolver.routeLookupKeys(for: resolve("KE0GB-7")),
            ["KE0GB-7"])
    }
}
