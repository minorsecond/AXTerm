//
//  PacketNSTableViewTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/4/26.
//

import XCTest
@testable import AXTerm

final class PacketNSTableViewTests: XCTestCase {
    func testAutosaveNameMatchesExpectation() {
        XCTAssertEqual(PacketNSTableView.Constants.autosaveName, "PacketTable")
    }

    func testColumnIdentifiersMatchExpectedOrder() {
        let identifiers = PacketNSTableView.ColumnIdentifier.allCases.map { $0.rawValue }
        XCTAssertEqual(identifiers, ["time", "from", "to", "via", "type", "info"])
    }

    func testAutoresizingColumnIdentifierIsInfo() {
        XCTAssertEqual(PacketNSTableView.Constants.autoresizingColumnIdentifier, .info)
    }
}
