//
//  PayloadTokenExtractorTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/1/26.
//

import XCTest
@testable import AXTerm

final class PayloadTokenExtractorTests: XCTestCase {
    func testDetectsCallsignSuffixTokens() {
        let payload = "KB5YZB/R YZBBPQ/D KB5YZB-1/B KB5YZB-7/N"

        let summary = PayloadTokenExtractor.summarize(text: payload)

        XCTAssertEqual(summary.callsigns, ["KB5YZB/R", "YZBBPQ/D", "KB5YZB-1/B", "KB5YZB-7/N"])
    }

    func testDoesNotTreatSingleLettersAsCallsigns() {
        let payload = "R D /R K"

        let summary = PayloadTokenExtractor.summarize(text: payload)

        XCTAssertTrue(summary.callsigns.isEmpty)
    }

    func testPreservesDigipeaterStar() {
        let payload = "DRLNOD*"

        let summary = PayloadTokenExtractor.summarize(text: payload)

        XCTAssertEqual(summary.callsigns, ["DRLNOD*"])
    }
}
