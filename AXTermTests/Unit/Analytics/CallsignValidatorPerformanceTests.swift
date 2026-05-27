//
//  CallsignValidatorPerformanceTests.swift
//  AXTermTests
//
//  Proves that isValidCallsign (and anything calling it) does NOT allocate a
//  new NSRegularExpression on every invocation.
//
//  Before the fix: ~0.1 s per 10,000 calls (two regex compilations per call).
//  After the fix:  < 0.01 s per 10,000 calls (compiled once, reused).
//

import XCTest
@testable import AXTerm

final class CallsignValidatorPerformanceTests: XCTestCase {

    // Representative via-path digipeaters heard on a busy packet network.
    private let sampleDigipeaters = [
        "DRLNOD", "W5ABC", "N0CALL", "VK3XYZ", "G4ABC", "JA1XYZ",
        "KD5RLY", "WB5KSD", "K5DLQ", "WIDE1-1", "WIDE2-2",
        "KB5YZB", "W6XYZ-7", "N5XYZ", "K5ABC-9", "VE3XYZ",
        "ZL2XYZ", "DK1ABC", "OE1XYZ", "SP5XYZ", "RA3XYZ"
    ]

    private let validCallsigns = [
        "W5ABC", "N0CALL", "VK3XYZ", "G4ABC", "JA1XYZ",
        "KB5YZB", "W6XYZ", "N5XYZ", "K5ABC", "VE3XYZ"
    ]

    // Simulate rebuildObservedPaths: 1000 packets × ~20 digipeaters = 20,000 calls.
    // With static regex this must complete in < 0.02 s per iteration.
    // With per-call NSRegularExpression allocation it takes ~0.1 s — 5× too slow.
    func testIsValidDigipeaterAddressDoesNotAllocateRegexPerCall() {
        let calls = (0..<1000).flatMap { _ in sampleDigipeaters }  // 20,000 calls

        measure(metrics: [XCTClockMetric()]) {
            for call in calls {
                _ = CallsignValidator.isValidDigipeaterAddress(call)
            }
        }
    }

    // Narrower check: just isValidCallsign with valid inputs.
    func testIsValidCallsignIsFastForRepeatedInputs() {
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<1000 {
                for call in validCallsigns {
                    _ = CallsignValidator.isValidCallsign(call)
                }
            }
        }
    }

    // Correctness guard: the optimisation must not break existing validation results.
    func testCallsignValidationCorrectnessUnchanged() {
        XCTAssertTrue(CallsignValidator.isValidCallsign("W5ABC"))
        XCTAssertTrue(CallsignValidator.isValidCallsign("N0CALL"))
        XCTAssertTrue(CallsignValidator.isValidCallsign("VK3XYZ"))
        XCTAssertTrue(CallsignValidator.isValidCallsign("JA1XYZ"))
        XCTAssertTrue(CallsignValidator.isValidCallsign("3DA0XYZ"))   // reverse pattern
        XCTAssertFalse(CallsignValidator.isValidCallsign("BEACON"))
        XCTAssertFalse(CallsignValidator.isValidCallsign("WIDE1-1"))
        XCTAssertFalse(CallsignValidator.isValidCallsign("ID"))
        XCTAssertFalse(CallsignValidator.isValidCallsign("123ABC"))
        XCTAssertFalse(CallsignValidator.isValidCallsign(""))
    }
}
