//
//  NetRomRelayProgressTests.swift
//  AXTermTests
//
//  The status strip's hop-by-hop answer to "which node is being negotiated
//  with right now". Walked against the ASHCHT field chain of 2026-08-28:
//  You → DRLNOD → KB5YZB-7 → COSCO → ASHCHT, phase by phase, exactly as
//  the relay's own state moved that evening.
//

import XCTest
@testable import AXTerm

final class NetRomRelayProgressTests: XCTestCase {

    private let chain = ["DRLNOD", "KB5YZB-7", "COSCO"]

    private func states(remaining: Int, askInFlight: Bool,
                        established: Bool = false) -> [NetRomRelayProgress.HopState] {
        NetRomRelayProgress.hops(chain: chain, destination: "ASHCHT",
                                 remainingCount: remaining,
                                 askInFlight: askInFlight,
                                 established: established).map(\.state)
    }

    // MARK: - The ASHCHT walk, phase by phase

    /// Armed, SABM out, waiting for DRLNOD's banner.
    func testWaitingForTheFirstBanner() {
        XCTAssertEqual(states(remaining: 2, askInFlight: false),
                       [.active, .pending, .pending, .pending])
    }

    /// DRLNOD greeted; `C KB5YZB-7` is out. The eye belongs on the node
    /// being connected toward, not the one that already answered.
    func testAskInFlightMovesTheEyeForward() {
        XCTAssertEqual(states(remaining: 2, askInFlight: true),
                       [.done, .active, .pending, .pending])
    }

    /// `###LINK MADE` — the hop is behind us, KB5YZB-7 owes its banner.
    func testHopMadeWaitingForTheNextBanner() {
        XCTAssertEqual(states(remaining: 1, askInFlight: false),
                       [.done, .active, .pending, .pending])
    }

    /// The last chain node greeted and `C ASHCHT` is out — the destination
    /// itself is what is being negotiated.
    func testTheFinalAskPutsTheDestinationInFlight() {
        XCTAssertEqual(states(remaining: 0, askInFlight: true),
                       [.done, .done, .done, .active])
    }

    /// Circuit up end to end.
    func testEstablishedIsAllDone() {
        XCTAssertEqual(states(remaining: 0, askInFlight: false, established: true),
                       [.done, .done, .done, .done])
    }

    // MARK: - Shapes and edges

    /// A one-hop relay (teller reachable directly) still tells its story:
    /// the node, then the destination.
    func testAOneHopRelayIsTwoChips() {
        let hops = NetRomRelayProgress.hops(chain: ["DRLNOD"], destination: "EVANS",
                                            remainingCount: 0,
                                            askInFlight: false, established: false)
        XCTAssertEqual(hops.map(\.name), ["DRLNOD", "EVANS"])
        XCTAssertEqual(hops.map(\.state), [.active, .pending])
    }

    /// No chain, no row — an ordinary connect must not grow a progress strip.
    func testNoChainRendersNothing() {
        XCTAssertTrue(NetRomRelayProgress.hops(chain: [], destination: "ASHCHT",
                                               remainingCount: 0,
                                               askInFlight: false,
                                               established: false).isEmpty)
    }

    /// Position is the identity, not the name: two chips never collapse even
    /// if a planner bug repeated a node.
    func testIdsAreChainPositions() {
        let hops = NetRomRelayProgress.hops(chain: ["A", "A"], destination: "B",
                                            remainingCount: 1,
                                            askInFlight: false, established: false)
        XCTAssertEqual(hops.map(\.id), [0, 1, 2])
    }

    /// A remaining count that is out of step with the chain (nil-coalesced
    /// callers, future refactors) clamps rather than crashes or points past
    /// the destination.
    func testOutOfRangeCountsClamp() {
        XCTAssertEqual(states(remaining: 99, askInFlight: false),
                       [.active, .pending, .pending, .pending])
        let past = NetRomRelayProgress.hops(chain: ["DRLNOD"], destination: "EVANS",
                                            remainingCount: 0,
                                            askInFlight: true, established: false)
        XCTAssertEqual(past.map(\.state), [.done, .active],
                       "the ask past the last node lands on the destination")
    }
}
