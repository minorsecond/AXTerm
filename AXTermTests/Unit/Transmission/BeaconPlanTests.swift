import XCTest
@testable import AXTerm

/// Everything this rejects is something that would otherwise be on the air.
final class BeaconPlanTests: XCTestCase {

    func testPlainBeaconGoesOutDirect() {
        guard case let .success(beacon) = BeaconPlan.plan(
            text: "  K0EPI AXTerm packet station, Denver CO  ", path: "") else {
            return XCTFail("should plan")
        }
        XCTAssertEqual(beacon.text, "K0EPI AXTerm packet station, Denver CO")
        XCTAssertTrue(beacon.digis.isEmpty)
    }

    /// Operators write paths however they write them; both separators and
    /// any spacing have to mean the same thing.
    func testPathAcceptsCommasSpacesAndBoth() {
        for path in ["DRL,WIDE2-1", "DRL WIDE2-1", " DRL , WIDE2-1 ", "drl,wide2-1"] {
            guard case let .success(beacon) = BeaconPlan.plan(text: "hi", path: path) else {
                return XCTFail(path)
            }
            XCTAssertEqual(beacon.digis, ["DRL", "WIDE2-1"], path)
        }
    }

    func testEmptyTextIsRefused() {
        XCTAssertEqual(BeaconPlan.plan(text: "   \n ", path: ""), .failure(.emptyText))
    }

    /// Length is counted in bytes, not characters: the AX.25 info field
    /// does not care that an emoji looked like one character.
    func testLengthIsMeasuredInBytes() {
        let long = String(repeating: "é", count: BeaconPlan.maxTextBytes)
        guard case let .failure(problem) = BeaconPlan.plan(text: long, path: "") else {
            return XCTFail("2-byte characters should overflow at half the count")
        }
        XCTAssertEqual(problem, .textTooLong(bytes: BeaconPlan.maxTextBytes * 2))
    }

    func testTextAtTheLimitIsAccepted() {
        let exact = String(repeating: "a", count: BeaconPlan.maxTextBytes)
        guard case .success = BeaconPlan.plan(text: exact, path: "") else {
            return XCTFail("the limit is inclusive")
        }
    }

    func testTooManyDigisIsRefused() {
        let nine = (1...9).map { "HOP\($0)" }.joined(separator: ",")
        XCTAssertEqual(BeaconPlan.plan(text: "hi", path: nine),
                       .failure(.tooManyDigis(count: 9)))
    }

    func testEightDigisIsTheCeilingNotTheRefusal() {
        let eight = (1...8).map { "HOP\($0)" }.joined(separator: ",")
        guard case let .success(beacon) = BeaconPlan.plan(text: "hi", path: eight) else {
            return XCTFail("AX.25 allows eight")
        }
        XCTAssertEqual(beacon.digis.count, 8)
    }

    /// `WIDE1-1` and a bare alias like `DRL` are both ordinary path
    /// entries. A licence-shaped test would reject both.
    func testAliasesAndWidePathsAreCallsignShaped() {
        for path in ["WIDE1-1", "WIDE2-2", "DRL", "K0EPI-15", "N0CALL-0"] {
            guard case .success = BeaconPlan.plan(text: "hi", path: path) else {
                return XCTFail(path)
            }
        }
    }

    func testMalformedDigisAreRefused() {
        for bad in ["K0EPI-16", "TOOLONGCALL", "K0EPI-", "K0*PI", "-3"] {
            guard case let .failure(problem) = BeaconPlan.plan(text: "hi", path: bad) else {
                return XCTFail(bad)
            }
            XCTAssertEqual(problem, .malformedDigi(bad.uppercased()), bad)
        }
    }

    // MARK: - Path on its own

    /// An APRS position beacon has no operator-written text — its info field
    /// is generated from a fix — but it has the same path. Validating it used
    /// to mean inventing a body to hang the path on.
    func testAPathValidatesWithoutABody() {
        guard case let .success(digis) = BeaconPlan.planPath("WIDE1-1, WIDE2-1") else {
            return XCTFail("a normal APRS path should plan")
        }
        XCTAssertEqual(digis, ["WIDE1-1", "WIDE2-1"])
    }

    func testAnEmptyPathIsDirectAndFine() {
        guard case let .success(digis) = BeaconPlan.planPath("") else {
            return XCTFail("direct is a path")
        }
        XCTAssertTrue(digis.isEmpty)
    }

    func testABadDigipeaterStillFails() {
        guard case let .failure(problem) = BeaconPlan.planPath("WIDE1-1, TOOLONGCALL") else {
            return XCTFail("that is not a callsign")
        }
        XCTAssertEqual(problem, .malformedDigi("TOOLONGCALL"))
    }
}
