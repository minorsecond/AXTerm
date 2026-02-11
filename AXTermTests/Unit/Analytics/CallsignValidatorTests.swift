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

    func testCustomIgnoredServiceEndpointsAreRespected() {
        CallsignValidator.configureIgnoredServiceEndpoints(["HORSE", "drlnod"])
        XCTAssertFalse(CallsignValidator.isValidRoutingNode("HORSE"))
        XCTAssertFalse(CallsignValidator.isValidRoutingNode("DRLNOD"))
        XCTAssertTrue(CallsignValidator.isValidRoutingNode("DRL"))
    }
}
