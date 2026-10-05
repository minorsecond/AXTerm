//
//  RawTerminalFieldLayoutTests.swift
//  AXTermTests
//
//  The raw field is one line high whatever it is offered. Smoke run
//  2026-10-03-1, test 10.1: it took half the window, because its key view
//  has no height of its own.
//

#if os(macOS)
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class RawTerminalFieldLayoutTests: XCTestCase {

    func testTheRawFieldIsOneLineHighWhateverItIsOffered() {
        let host = NSHostingController(rootView: RawTerminalField(
            prompt: "BBS> ", echo: "dir", isEnabled: true, onKey: { _ in }))
        let size = host.sizeThatFits(in: CGSize(width: 600, height: 1000))
        XCTAssertEqual(size.height, RawTerminalField.fieldHeight, accuracy: 0.5)
    }
}
#endif
