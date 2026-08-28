import XCTest
@testable import AXTerm

/// Reading a relay hop's outcome from the node's outward link.
///
/// Replays the shapes seen on air on 2026-08-27, when DRLNOD was asked for
/// KB5YZB-7 and dialled it as `K0EPI-6` — our callsign, an SSID we had never
/// used. The UA came back four seconds before DRLNOD said `###LINK MADE`, and
/// on the next hop that announcement was lost entirely.
final class RelayLegWitnessTests: XCTestCase {

    private func witness() -> RelayLegWitness {
        RelayLegWitness(localCallsign: "K0EPI-7", answers: ["K0EPI-7", "K0EPI-1"])
    }

    /// The capture, in order: we ask, the node dials out as us, the far end
    /// answers, and the hop is up without anyone having said a word about it.
    func testUAOnTheNodesOutwardLinkMakesTheHop() {
        var w = witness()
        w.expect("KB5YZB-7")
        XCTAssertNil(w.observe(from: "K0EPI-6", to: "KB5YZB-7", uType: .SABM))
        XCTAssertEqual(w.observe(from: "KB5YZB-7", to: "K0EPI-6", uType: .UA),
                       .made(hop: "KB5YZB-7"))
    }

    /// DM is a refusal in the protocol itself — no node's wording required.
    func testDMIsARefusal() {
        var w = witness()
        w.expect("KB5YZB-7")
        _ = w.observe(from: "K0EPI-6", to: "KB5YZB-7", uType: .SABM)
        XCTAssertEqual(w.observe(from: "KB5YZB-7", to: "K0EPI-6", uType: .DM),
                       .refused(hop: "KB5YZB-7"))
    }

    /// Without the outgoing SABM the borrowed SSID is unknown, and an answer
    /// addressed to it is indistinguishable from traffic between strangers.
    func testAnAnswerToAnUnlearnedSSIDIsNotEvidence() {
        var w = witness()
        w.expect("KB5YZB-7")
        XCTAssertNil(w.observe(from: "KB5YZB-7", to: "K0EPI-6", uType: .UA))
    }

    /// Our own link to the node is on the air at exactly this moment, and its
    /// UA says nothing about any hop.
    func testOurOwnAddressesAreNotTheBorrowedOne() {
        var w = witness()
        w.expect("KB5YZB-7")
        XCTAssertNil(w.observe(from: "K0EPI-7", to: "KB5YZB-7", uType: .SABM))
        XCTAssertNil(w.observe(from: "KB5YZB-7", to: "K0EPI-7", uType: .UA))
    }

    /// Another operator connecting to the same node, at the same time, is the
    /// obvious way to read a stranger's success as our own.
    func testSomebodyElsesConnectToTheSameHopIsIgnored() {
        var w = witness()
        w.expect("KB5YZB-7")
        XCTAssertNil(w.observe(from: "W0ARP-10", to: "KB5YZB-7", uType: .SABM))
        XCTAssertNil(w.observe(from: "KB5YZB-7", to: "W0ARP-10", uType: .UA))
    }

    /// The verdict has to be about the hop we are waiting on. A node with
    /// several circuits open under borrowed SSIDs answers more than one.
    func testAVerdictFromADifferentStationIsIgnored() {
        var w = witness()
        w.expect("KB5YZB-7")
        _ = w.observe(from: "K0EPI-6", to: "KB5YZB-7", uType: .SABM)
        XCTAssertNil(w.observe(from: "K0NTS-10", to: "K0EPI-6", uType: .UA))
    }

    /// Disarmed between hops: the next ask learns its own SSID, and a late UA
    /// for the previous one must not advance the chain twice.
    func testStopWatchingEndsTheWindow() {
        var w = witness()
        w.expect("KB5YZB-7")
        _ = w.observe(from: "K0EPI-6", to: "KB5YZB-7", uType: .SABM)
        w.stopWatching()
        XCTAssertNil(w.observe(from: "KB5YZB-7", to: "K0EPI-6", uType: .UA))
    }

    /// Nothing is watched until a hop has been asked for.
    func testUnarmedWitnessReportsNothing() {
        var w = witness()
        XCTAssertNil(w.observe(from: "K0EPI-6", to: "KB5YZB-7", uType: .SABM))
        XCTAssertNil(w.observe(from: "KB5YZB-7", to: "K0EPI-6", uType: .UA))
    }

    /// DISC, FRMR, XID and the rest carry no verdict. Reading any U-frame as
    /// success would call a teardown a connection.
    func testOtherUFramesCarryNoVerdict() {
        var w = witness()
        w.expect("KB5YZB-7")
        _ = w.observe(from: "K0EPI-6", to: "KB5YZB-7", uType: .SABM)
        for uType: AX25UType in [.DISC, .FRMR, .XID, .UI, .UNKNOWN] {
            XCTAssertNil(w.observe(from: "KB5YZB-7", to: "K0EPI-6", uType: uType), uType.rawValue)
        }
        XCTAssertNil(w.observe(from: "KB5YZB-7", to: "K0EPI-6", uType: nil))
    }

    /// Case and padding come from wherever the caller got the string.
    func testMatchingIsCaseAndPaddingInsensitive() {
        var w = witness()
        w.expect(" kb5yzb-7 ")
        XCTAssertNil(w.observe(from: "k0epi-6", to: "kb5yzb-7", uType: .SABME))
        XCTAssertEqual(w.observe(from: " KB5YZB-7", to: "K0EPI-6 ", uType: .UA),
                       .made(hop: "KB5YZB-7"))
    }
}
