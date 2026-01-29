//
//  SelectionMutationSchedulerTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 3/2/26.
//

import XCTest
@testable import AXTerm

@MainActor
final class SelectionMutationSchedulerTests: XCTestCase {
    func testScheduleDefersMutationUntilYield() async {
        let scheduler = SelectionMutationScheduler()
        var value = 0

        scheduler.schedule {
            value += 1
        }

        XCTAssertEqual(value, 0)

        await Task.yield()
        await Task.yield()

        XCTAssertEqual(value, 1)
    }

    func testScheduleCancelsPreviousMutation() async {
        let scheduler = SelectionMutationScheduler()
        var value = 0

        scheduler.schedule {
            value = 1
        }
        scheduler.schedule {
            value = 2
        }

        await Task.yield()
        await Task.yield()

        XCTAssertEqual(value, 2)
    }
}
