//
//  KeptAliveFrameTests.swift
//  AXTermTests
//
//  A page kept mounted behind the others must not set the window's minimum
//  size.
//
//  Smoke run 2026-10-03-1, issue 22: the map stays mounted under every page,
//  hidden with opacity, and its banners and lists grew as stations were
//  heard. Opacity does not take a view out of layout, so the main window's
//  minimum height followed the hidden map past the screen (1109 points, then
//  2064, on a 1050-point screen). SwiftUI then resized the window during
//  layout, AppKit threw, and Station A crashed; at other times the page drew
//  shifted up with its toolbar above the window.
//

#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class KeptAliveFrameTests: XCTestCase {

    /// Text that cannot shrink vertically and wraps to many lines when the
    /// window is asked how narrow and short it can be, like the map's
    /// banner captions.
    private var tallContent: some View {
        VStack(spacing: 0) {
            ForEach(0..<40, id: \.self) { index in
                Text("Heard station \(index) has no known position, so it is listed and not drawn.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The height a window must be at least, as AppKit asks for it: the
    /// size the content needs when offered nothing.
    private func minimumHeight<V: View>(_ view: V) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: .zero).height
    }

    func testUnwrappedContentDemandsItsFullHeight() {
        XCTAssertGreaterThan(minimumHeight(tallContent), 1050,
                             "the measurement must see the problem, or the next test proves nothing")
    }

    func testAKeptAlivePageAsksForNoMinimumHeight() {
        XCTAssertLessThan(minimumHeight(tallContent.keptAliveFrame()), 1)
    }

    /// Behind another page in a ZStack, as the map is: the page in front
    /// alone decides the minimum.
    func testThePageInFrontDecidesTheMinimum() {
        let stack = ZStack {
            Color.clear.frame(minHeight: 300)
            tallContent.keptAliveFrame().opacity(0)
        }
        XCTAssertEqual(minimumHeight(stack), 300, accuracy: 1)
    }
}
#endif
