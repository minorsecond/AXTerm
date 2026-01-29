//
//  GraphSelectionReducerTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2026-02-23.
//

import XCTest
@testable import AXTerm

final class GraphSelectionReducerTests: XCTestCase {
    func testClickSelects() {
        var state = GraphSelectionState()

        let effect = GraphSelectionReducer.reduce(
            state: &state,
            action: .clickNode(id: "alpha", isShift: false)
        )

        XCTAssertEqual(effect, .none)
        XCTAssertEqual(state.selectedIDs, ["alpha"])
        XCTAssertEqual(state.primarySelectionID, "alpha")
    }

    func testClickOutsideClears() {
        var state = GraphSelectionState(selectedIDs: ["alpha", "beta"], primarySelectionID: "alpha")

        let effect = GraphSelectionReducer.reduce(state: &state, action: .clickBackground)

        XCTAssertEqual(effect, .none)
        XCTAssertTrue(state.selectedIDs.isEmpty)
        XCTAssertNil(state.primarySelectionID)
    }

    func testDoubleClickTriggersInspect() {
        var state = GraphSelectionState()

        let effect = GraphSelectionReducer.reduce(
            state: &state,
            action: .doubleClickNode(id: "alpha", isShift: false)
        )

        XCTAssertEqual(effect, .inspect("alpha"))
        XCTAssertEqual(state.selectedIDs, ["alpha"])
        XCTAssertEqual(state.primarySelectionID, "alpha")
    }
}
