//
//  NetworkPathObserverTests.swift
//  AXTermTests
//
//  Topology from overhearing. Distinct from NetRomRouter, which answers "how
//  would *we* reach this destination" — this answers "what paths exist on this
//  channel at all", including between two other stations. On a network with no
//  NET/ROM broadcasts, overhearing is the only source of topology there is.
//

import XCTest
@testable import AXTerm

final class NetworkPathObserverTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func address(_ text: String, repeated: Bool = false) -> AX25Address {
        let parts = text.split(separator: "-")
        return AX25Address(call: String(parts[0]),
                           ssid: parts.count > 1 ? Int(parts[1]) ?? 0 : 0,
                           repeated: repeated)
    }

    private func packet(_ from: String, _ to: String,
                        via: [AX25Address] = [],
                        type: FrameType = .ui,
                        control: UInt8 = 0x03,
                        at offset: TimeInterval = 0) -> Packet {
        Packet(timestamp: t0.addingTimeInterval(offset),
               from: address(from), to: address(to), via: via,
               frameType: type, control: control, infoText: "x")
    }

    private func path(_ paths: [NetworkPath], between a: String, and b: String) -> NetworkPath? {
        paths.first {
            Set([$0.from, $0.to]) == Set([a, b])
        }
    }

    // MARK: - Direct and digipeated

    func testADirectFrameIsADirectPath() {
        let paths = NetworkPathObserver.paths(in: [packet("K0NTS-1", "N3HYM-15")])
        XCTAssertEqual(path(paths, between: "K0NTS-1", and: "N3HYM-15")?.evidence, .heardDirect)
    }

    func testARepeatedHopMakesItADigipeatedPath() {
        let paths = NetworkPathObserver.paths(in: [
            packet("KB5YZB-7", "K0NTS-1", via: [address("DRLNOD", repeated: true)]),
        ])
        let found = try? XCTUnwrap(path(paths, between: "KB5YZB-7", and: "K0NTS-1"))
        XCTAssertEqual(found?.evidence, .heardDigipeated)
        XCTAssertEqual(found?.via, ["DRLNOD"])
    }

    func testAnUnrepeatedHopIsNotPartOfThePathTravelled() {
        // H=0 is the frame on its way *to* the digi. Recording it as a hop
        // would claim a path that has not yet been travelled.
        let paths = NetworkPathObserver.paths(in: [
            packet("KB5YZB-7", "K0NTS-1", via: [address("DRLNOD", repeated: false)]),
        ])
        XCTAssertEqual(path(paths, between: "KB5YZB-7", and: "K0NTS-1")?.via, [])
    }

    func testDestinationsThatAreNotStationsAreIgnored() {
        let paths = NetworkPathObserver.paths(in: [packet("KD0SSP", "BEACON")])
        XCTAssertTrue(paths.isEmpty, "a path to BEACON is a category error")
    }

    // MARK: - The strongest evidence

    func testAnAnsweredConnectProvesThePathBothWays() {
        // SABM out, UA back over the same path. Nothing else observed here
        // proves a path end to end.
        let paths = NetworkPathObserver.paths(in: [
            packet("K0NTS-1", "KF0BPN-1", type: .u, control: 0x2F, at: 0),
            packet("KF0BPN-1", "K0NTS-1", type: .u, control: 0x63, at: 3),
        ])
        XCTAssertEqual(path(paths, between: "K0NTS-1", and: "KF0BPN-1")?.evidence,
                       .sessionEstablished)
    }

    func testARefusalStillProvesThePath() {
        // DM means "reachable, not listening". The session failed; the path
        // demonstrably did not.
        let paths = NetworkPathObserver.paths(in: [
            packet("K0EPI-7", "W0ARP-10", type: .u, control: 0x2F, at: 0),
            packet("W0ARP-10", "K0EPI-7", type: .u, control: 0x0F, at: 2),
        ])
        XCTAssertEqual(path(paths, between: "K0EPI-7", and: "W0ARP-10")?.evidence,
                       .sessionEstablished)
    }

    func testAnAnswerLongAfterTheWindowDoesNotCount() {
        let late = NetworkPathObserver.answerWindow + 60
        let paths = NetworkPathObserver.paths(in: [
            packet("K0NTS-1", "KF0BPN-1", type: .u, control: 0x2F, at: 0),
            packet("KF0BPN-1", "K0NTS-1", type: .u, control: 0x63, at: late),
        ])
        // Two unrelated events minutes apart are not a handshake.
        XCTAssertNotEqual(path(paths, between: "K0NTS-1", and: "KF0BPN-1")?.evidence,
                          .sessionEstablished)
    }

    // MARK: - Negative evidence

    func testAnUnansweredConnectIsCountedAgainstThePath() {
        // Exactly the KF0BPN-1 case: K0NTS-1 called it every six seconds and
        // nothing ever came back.
        var packets: [Packet] = []
        for i in 0..<4 {
            packets.append(packet("K0NTS-1", "KF0BPN-1", type: .u,
                                  control: 0x2F, at: Double(i) * 6))
        }
        packets.append(packet("KD0SSP", "K0NTS-1",
                              at: NetworkPathObserver.answerWindow + 30))

        let found = try? XCTUnwrap(
            path(NetworkPathObserver.paths(in: packets),
                 between: "K0NTS-1", and: "KF0BPN-1"))
        XCTAssertGreaterThan(found?.unansweredAttempts ?? 0, 0)
        XCTAssertTrue(found?.isSuspect ?? false,
                      "a path that never answers is the one that wastes the most airtime")
    }

    func testAPathThatCompletedIsNeverSuspect() {
        let paths = NetworkPathObserver.paths(in: [
            packet("K0NTS-1", "N3HYM-15", type: .u, control: 0x2F, at: 0),
            packet("N3HYM-15", "K0NTS-1", type: .u, control: 0x63, at: 2),
        ])
        XCTAssertFalse(path(paths, between: "K0NTS-1", and: "N3HYM-15")?.isSuspect ?? true)
    }

    // MARK: - Merging

    func testAPathIsUndirected() {
        let paths = NetworkPathObserver.paths(in: [
            packet("K0NTS-1", "N3HYM-15"),
            packet("N3HYM-15", "K0NTS-1"),
        ])
        // Listing both directions separately would double every edge on a map.
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths.first?.observations, 2)
    }

    func testStrongerEvidenceWins() {
        let paths = NetworkPathObserver.paths(in: [
            packet("K0NTS-1", "N3HYM-15", at: 0),
            packet("K0NTS-1", "N3HYM-15", type: .u, control: 0x2F, at: 1),
            packet("N3HYM-15", "K0NTS-1", type: .u, control: 0x63, at: 2),
        ])
        XCTAssertEqual(paths.first?.evidence, .sessionEstablished)
    }

    // MARK: - Transitive inference

    func testTwoStationsSharingADigipeaterGetAnInferredPath() {
        let observed = NetworkPathObserver.paths(in: [
            packet("KB5YZB-7", "K0NTS-1", via: [address("DRLNOD", repeated: true)]),
            packet("AB0VZ", "KD0SSP", via: [address("DRLNOD", repeated: true)]),
        ])
        let inferred = NetworkPathObserver.transitivePaths(from: observed, now: t0)

        // KB5YZB-7 and AB0VZ have never exchanged a frame, but both reach
        // DRLNOD, so a path through it is plausible.
        XCTAssertNotNil(path(inferred, between: "KB5YZB-7", and: "AB0VZ"))
        XCTAssertTrue(inferred.allSatisfy { $0.evidence == .transitive })
    }

    func testInferenceNeverRestatesSomethingAlreadyObserved() {
        let observed = NetworkPathObserver.paths(in: [
            packet("KB5YZB-7", "K0NTS-1", via: [address("DRLNOD", repeated: true)]),
        ])
        let inferred = NetworkPathObserver.transitivePaths(from: observed, now: t0)
        // These two were seen talking; calling that "inferred" would weaken a
        // fact we already have.
        XCTAssertNil(path(inferred, between: "KB5YZB-7", and: "K0NTS-1"))
    }

    func testInferenceCarriesTheWeakestEvidenceOnPurpose() {
        XCTAssertLessThan(NetworkPath.Evidence.transitive, .heardDirect)
        XCTAssertLessThan(NetworkPath.Evidence.heardDirect, .heardDigipeated)
        XCTAssertLessThan(NetworkPath.Evidence.heardDigipeated, .sessionEstablished)
    }

    func testEveryEvidenceLevelExplainsItself() {
        for evidence in NetworkPath.Evidence.allCases {
            XCTAssertFalse(evidence.label.isEmpty)
            XCTAssertFalse(evidence.explanation.isEmpty)
        }
    }
}
