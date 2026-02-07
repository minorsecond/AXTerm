//
//  StationNormalizerTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2026-02-18.
//

import XCTest
@testable import AXTerm

final class StationNormalizerTests: XCTestCase {
    func testNormalizeNilReturnsNil() {
        XCTAssertNil(StationNormalizer.normalize(nil))
    }

    func testNormalizeEmptyReturnsNil() {
        XCTAssertNil(StationNormalizer.normalize(""))
        XCTAssertNil(StationNormalizer.normalize("   "))
    }

    func testNormalizeQuestionMarkReturnsNil() {
        XCTAssertNil(StationNormalizer.normalize("?"))
        XCTAssertNil(StationNormalizer.normalize(" ? "))
    }

    func testNormalizeUppercasesAndTrims() {
        XCTAssertEqual(StationNormalizer.normalize(" n0call-1 "), "N0CALL-1")
    }
}
