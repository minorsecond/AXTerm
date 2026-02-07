//
//  PayloadFormatterTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 1/28/26.
//

import XCTest
@testable import AXTerm

final class PayloadFormatterTests: XCTestCase {

    func testASCIIStringReplacesNonPrintable() {
        let data = Data([0x41, 0x42, 0x00, 0x7F, 0x20])
        let result = PayloadFormatter.asciiString(data)
        XCTAssertEqual(result, "AB·· ")
    }

    func testHexStringFormatting() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let result = PayloadFormatter.hexString(data, bytesPerLine: 2)
        XCTAssertEqual(result, "01 02\n03 04")
    }
}
