//
//  CallsignValidatorTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/4/26.
//

import XCTest
@testable import AXTerm

final class CallsignValidatorTests: XCTestCase {
    func testCallsignValidationAcceptsStandardFormats() {
        XCTAssertTrue(CallsignValidator.isValid("N0CALL"))
        XCTAssertTrue(CallsignValidator.isValid("n0call-7"))
        XCTAssertFalse(CallsignValidator.isValid("1234"))
        XCTAssertFalse(CallsignValidator.isValid("N0CALL-123"))
    }

    func testCallsignNormalizationUppercases() {
        XCTAssertEqual(CallsignValidator.normalize(" n0call-7 "), "N0CALL-7")
    }
}
