//
//  ConsoleFilterMenuTests.swift
//  AXTermTests
//
//  On an iPhone the chip row had room for one chip, so the frame types
//  could not be reached; looking for RR frames, the operator could not tell
//  which chip held them (2026-10-12). On iOS the types go in a menu, each
//  named in words with the chip's label first.
//

import XCTest
@testable import AXTerm

final class ConsoleFilterMenuTests: XCTestCase {

    func testEachTypeIsNamedInWords() {
        XCTAssertEqual(ConsoleTypeFilterFlags.Kind.prompt.menuTitle, "CMD: link control (SABM, RR, UA, DISC)")
        XCTAssertEqual(ConsoleTypeFilterFlags.Kind.id.menuTitle, "ID: station identification")
        XCTAssertEqual(ConsoleTypeFilterFlags.Kind.mine.menuTitle, "MINE: only traffic you are part of")
    }

    func testEveryTypeHasOne() {
        for kind in ConsoleTypeFilterFlags.Kind.messageClasses + [.mine, .digipeats] {
            XCTAssertTrue(kind.menuTitle.hasPrefix(kind.label + ": "), "\(kind)")
        }
    }
}
