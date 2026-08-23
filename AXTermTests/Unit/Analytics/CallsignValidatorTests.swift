//
//  CallsignValidatorTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/4/26.
//

import XCTest
@testable import AXTerm

final class CallsignValidatorTests: XCTestCase {
    override func tearDown() {
        CallsignValidator.configureIgnoredServiceEndpoints([])
        super.tearDown()
    }

    func testCallsignValidationAcceptsStandardFormats() {
        XCTAssertTrue(CallsignValidator.isValid("N0CALL"))
        XCTAssertTrue(CallsignValidator.isValid("n0call-7"))
        XCTAssertFalse(CallsignValidator.isValid("1234"))
        XCTAssertFalse(CallsignValidator.isValid("N0CALL-123"))
    }

    func testCallsignNormalizationUppercases() {
        XCTAssertEqual(CallsignValidator.normalize(" n0call-7 "), "N0CALL-7")
    }

    func testRoutingNodeValidationAllowsDigipeaterAliases() {
        XCTAssertTrue(CallsignValidator.isValidRoutingNode("DRL"))
        XCTAssertTrue(CallsignValidator.isValidRoutingNode("DRLNOD"))
        XCTAssertTrue(CallsignValidator.isValidRoutingNode("DRL-1"))
    }

    func testRoutingNodeValidationStillRejectsServiceEndpoints() {
        XCTAssertFalse(CallsignValidator.isValidRoutingNode("ID"))
        XCTAssertFalse(CallsignValidator.isValidRoutingNode("BEACON"))
        XCTAssertFalse(CallsignValidator.isValidRoutingNode("BBS"))
        XCTAssertFalse(CallsignValidator.isValidRoutingNode("WIDE1-1"))
    }

    func testNetRomBroadcastDestinationIsNotARoutingNode() {
        // "NODES" is the standard NET/ROM broadcast destination (PID 0xCF).
        // It matches the tactical-alias pattern, so without an explicit service
        // entry every NET/ROM node's broadcasts would grow a phantom "NODES"
        // station connected to the whole network.
        XCTAssertFalse(CallsignValidator.isValidRoutingNode("NODES"))
        XCTAssertFalse(CallsignValidator.isValidCallsign("NODES"))
    }

    func testCorruptDecodesAreRejectedByBothValidators() {
        // Real corrupt frames observed on air: symbols and control characters
        // must never become stations under either validator.
        for garbage in ["KVQ$U(", ":L|VR", ";\">CW:", "", "-", "--7"] {
            XCTAssertFalse(CallsignValidator.isValidCallsign(garbage), "strict must reject \(garbage)")
            XCTAssertFalse(CallsignValidator.isValidRoutingNode(garbage), "routing must reject \(garbage)")
        }
    }

    func testCallsignModelAcceptsTacticalAliases() {
        // Connecting to a NET/ROM node by alias is standard practice; the
        // Callsign model must accept what the network can address.
        XCTAssertEqual(Callsign("DRLNOD")?.stringValue, "DRLNOD")
        XCTAssertEqual(Callsign("drl-2")?.stringValue, "DRL-2")
        XCTAssertNil(Callsign("NODES"), "Broadcast destination is not addressable")
        XCTAssertNil(Callsign("BEACON"))
        XCTAssertNil(Callsign("KVQ$U("), "Corrupt garbage stays rejected")
    }

    func testCustomIgnoredServiceEndpointsAreRespected() {
        CallsignValidator.configureIgnoredServiceEndpoints(["HORSE", "drlnod"])
        XCTAssertFalse(CallsignValidator.isValidRoutingNode("HORSE"))
        XCTAssertFalse(CallsignValidator.isValidRoutingNode("DRLNOD"))
        XCTAssertTrue(CallsignValidator.isValidRoutingNode("DRL"))
    }
}
