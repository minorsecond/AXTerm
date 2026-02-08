//
//  CappedArrayTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 1/28/26.
//

import XCTest
@testable import AXTerm

final class CappedArrayTests: XCTestCase {

    func testCappedArrayMaintainsMaxSize() {
        var values: [Int] = []

        for index in 1...5 {
            CappedArray.append(index, to: &values, max: 3)
        }

        XCTAssertEqual(values, [3, 4, 5])
    }
}
