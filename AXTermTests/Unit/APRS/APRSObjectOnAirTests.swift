import XCTest
@testable import AXTerm

/// The object frames AXTerm composes, proven against a decoder that is not
/// AXTerm.
///
/// `APRSObjectComposeTests` round-trips through our own parser, which
/// establishes only that one implementation agrees with itself. These bytes
/// were transmitted through a real modem on the RF rig and described by
/// Direwolf's own APRS parser; this asserts AXTerm's production encoder emits
/// exactly them. Neither half rests on the code under test.
///
/// Regenerate with `TestRig/scripts/axterm_object_onair.py`.
final class APRSObjectOnAirTests: XCTestCase {

    /// The timestamp the capture used, so the bytes are reproducible.
    private let stamped = Date(timeIntervalSince1970: 1_757_419_200)   // 091200z

    private struct Capture: Decodable {
        struct Frame: Decodable {
            let name: String
            let info: String
            let decoded_by_direwolf: [String]
        }
        let stamp: String
        let frames: [Frame]
    }

    private func capture() throws -> Capture {
        let url = try XCTUnwrap(
            Bundle(for: APRSObjectOnAirTests.self)
                .url(forResource: "axterm-object-onair", withExtension: "json"),
            "axterm-object-onair.json is not in the test bundle")
        return try JSONDecoder().decode(Capture.self, from: Data(contentsOf: url))
    }

    /// What AXTerm builds for each frame in the capture, by the production
    /// path — the same call `SessionCoordinator.sendAPRSObject` makes.
    private func ours(_ name: String) -> String? {
        switch name {
        case "object-place":
            return APRSObjectReport.objectInfo(
                name: "ROADCLOSE", live: true, latitude: 39.6117, longitude: -104.7317,
                symbolTable: "/", symbolCode: "-", comment: "US-85 washed out", at: stamped)
        case "object-kill":
            return APRSObjectReport.killInfo(
                name: "ROADCLOSE", latitude: 39.6117, longitude: -104.7317,
                symbolTable: "/", symbolCode: "-", at: stamped)
        case "object-alternate-table":
            return APRSObjectReport.objectInfo(
                name: "FIRE", live: true, latitude: 39.6000, longitude: -104.7000,
                symbolTable: "\\", symbolCode: "!", comment: "structure fire", at: stamped)
        case "object-truncated-name":
            return APRSObjectReport.objectInfo(
                name: "EVACUATION ROUTE", live: true, latitude: 39.5000, longitude: -104.8000,
                symbolTable: "/", symbolCode: "+", at: stamped)
        default: return nil
        }
    }

    func testAXTermEmitsTheBytesThatWentOnTheAir() throws {
        let capture = try capture()
        XCTAssertEqual(capture.stamp, "091200z")
        XCTAssertFalse(capture.frames.isEmpty)
        for frame in capture.frames {
            let mine = try XCTUnwrap(ours(frame.name),
                                     "\(frame.name) is in the capture but not built here")
            XCTAssertEqual(mine, frame.info,
                           "\(frame.name) is no longer the frame that was proven; "
                           + "re-run TestRig/scripts/axterm_object_onair.py")
        }
    }

    /// Every frame we transmitted was actually decoded. A frame Direwolf
    /// silently dropped would otherwise pass the byte comparison above while
    /// being unreadable to the entire channel.
    func testEveryFrameWasDecodedByDirewolf() throws {
        for frame in try capture().frames {
            XCTAssertFalse(frame.decoded_by_direwolf.isEmpty,
                           "\(frame.name) was transmitted and nothing decoded it")
        }
    }

    /// And decoded as the thing we meant. The name and the position are what
    /// another operator acts on.
    func testDirewolfReadTheNameAndPositionWeIntended() throws {
        let expected = [
            "object-place":           ("ROADCLOSE", "N 39 36.7000", "W 104 43.9000"),
            "object-kill":            ("ROADCLOSE", "N 39 36.7000", "W 104 43.9000"),
            "object-alternate-table": ("FIRE",      "N 39 36.0000", "W 104 42.0000"),
            // Nine characters on the wire: the truncation is what everyone
            // else sees, and Direwolf confirms which nine.
            "object-truncated-name":  ("EVACUATIO", "N 39 30.0000", "W 104 48.0000"),
        ]
        for frame in try capture().frames {
            let (name, lat, lon) = try XCTUnwrap(expected[frame.name])
            let text = frame.decoded_by_direwolf.joined(separator: " ")
            XCTAssertTrue(text.contains("\"\(name)\""), "\(frame.name): \(text)")
            XCTAssertTrue(text.contains(lat), "\(frame.name) latitude: \(text)")
            XCTAssertTrue(text.contains(lon), "\(frame.name) longitude: \(text)")
        }
    }
}
