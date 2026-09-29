//
//  APRSFrameOriginTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

/// Telling a neighbour from a station piped in over the internet.
///
/// Every frame below is verbatim from the prod database, 2026-09-09/10 — the
/// 129 third-party frames on that channel, and the one station whose distance
/// makes it suspicious but whose frame says nothing at all.
final class APRSFrameOriginTests: XCTestCase {

    private func classify(_ info: String, via: [String] = []) -> APRSFrameOrigin {
        APRSFrameOrigin.classify(info: Data(info.utf8), via: via)
    }

    // MARK: - What the frame says outright

    func testAThirdPartyFrameNamesItsOriginatorAndItsGateway() {
        XCTAssertEqual(
            classify("}K0VJ-10>APFII0,TCPIP,W3OO-1*::OTA      :ack5421"),
            .gatedOntoRF(originator: "K0VJ-10", gateway: "W3OO-1"))

        XCTAssertEqual(
            classify("}SOTA>APZS20,TCPIP,WE0FUN-1*::N0IPA-7  :ack7DF8C"),
            .gatedOntoRF(originator: "SOTA", gateway: "WE0FUN-1"))

        XCTAssertEqual(
            classify("}YF3CJU-5>APDR16,TCPIP,K5RHD-10*::AK0U-4   :Hello"),
            .gatedOntoRF(originator: "YF3CJU-5", gateway: "K5RHD-10"))
    }

    func testEveryGatewaySeenOnThisChannelIsRecognised() {
        // The four stations doing the gating, by volume, in the prod log.
        for gateway in ["W3OO-1", "K5RHD-10", "KE0ZAB-1", "WE0FUN-1"] {
            let frame = "}N4TCW>APK102,TCPIP,\(gateway)*::KF0PIX-9 :YOU ARE TRANSMITTING"
            XCTAssertEqual(classify(frame).gateway, gateway)
            XCTAssertTrue(classify(frame).isFromInternet)
        }
    }

    func testAPlainFrameWhoseOwnPathIsMarkedCountsToo() {
        XCTAssertEqual(classify("!3937.00N/10443.00W-", via: ["TCPIP*"]), .internetPath)
        XCTAssertEqual(classify("!3937.00N/10443.00W-", via: ["TCPXX*"]), .internetPath)
        XCTAssertEqual(classify("!3937.00N/10443.00W-", via: ["qAC", "T2VAN"]), .internetPath)
    }

    // MARK: - What it does not say

    /// KC0AUH-2, Dodge City: 394 km away, and 370 km from the digi that
    /// repeated it — but its frame carries no internet marker at all. It must
    /// not be badged on suspicion; that is `StationPlausibility`'s job, and
    /// conflating the two would put a claim in the frame's mouth.
    func testADistantStationWithACleanPathIsNotBadged() {
        let origin = classify(
            "!3745.40ND10052.08W# Finney Co. Wide Area Digi Sponsor: W0MI, K0SUN",
            via: ["WA6IFI-6*"])
        XCTAssertEqual(origin, .radio)
        XCTAssertFalse(origin.isFromInternet)
        XCTAssertNil(origin.gateway)
    }

    /// A third-party frame is not automatically an internet frame: the same
    /// wrapper carries RF-to-RF relays. Claiming otherwise would have the
    /// operator discount a station they can actually reach.
    func testAThirdPartyRelayWithNoInternetMarkerIsNotClaimed() {
        XCTAssertEqual(classify("}K0EPI-7>APZAXT,WIDE1-1,W0ARP-10*::N0IPA-7  :hi"), .radio)
    }

    func testOrdinaryRFTrafficIsUntouched() {
        XCTAssertEqual(classify("!3933.48N/10447.65W#LSA WIDE1 DigiGate",
                                via: ["WIDE1-1*", "WIDE2-1"]), .radio)
        XCTAssertEqual(classify("T#132,173,043,006,091,051,00000000"), .radio)
        XCTAssertEqual(classify("`pG~l \u{1c}M/\"3r}testing"), .radio)
    }

    // MARK: - Malformed input

    func testAMalformedThirdPartyHeaderIsNotAClaim() {
        XCTAssertEqual(classify("}"), .radio)
        XCTAssertEqual(classify("}no-arrow-here:payload"), .radio)
        XCTAssertEqual(classify("}>APRS,TCPIP,W3OO-1*::x"), .radio, "no originator")
        XCTAssertEqual(classify("}K0VJ-10>APFII0,TCPIP,W3OO-1"), .radio, "no payload colon")
    }

    /// The marker test is case-insensitive and prefix-based: real paths carry
    /// `TCPIP*`, `qAC`, `qAR`, `qAS`, `qAO`.
    func testTheInternetMarkersAreRecognisedInEveryFormSeenOnTheAir() {
        for marker in ["TCPIP", "TCPIP*", "tcpip", "TCPXX", "qAC", "qAR", "qAS", "qAO", "QAC"] {
            XCTAssertTrue(APRSFrameOrigin.marksInternet(marker), "\(marker) should mark internet")
        }
        for marker in ["WIDE1-1", "WA6IFI-6", "K0EPI-7", "RFONLY", "NOGATE", ""] {
            XCTAssertFalse(APRSFrameOrigin.marksInternet(marker), "\(marker) is not an internet marker")
        }
    }
}
