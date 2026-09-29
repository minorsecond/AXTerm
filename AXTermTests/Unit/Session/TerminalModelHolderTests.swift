import XCTest
@testable import AXTerm

/// Keeping the terminal's view model alive across navigation.
///
/// `TerminalView` held it as `@StateObject`, so SwiftUI destroyed it whenever
/// the view lost its place in the hierarchy — which is exactly what opening
/// Nodes and coming back does. The AX.25 session survived, because it lives
/// in the coordinator; everything the view model knew *about* it did not.
///
/// Field capture 2026-08-31: `[ObservableTerminalTxViewModel.init]` logged at
/// 08:18:15, beside the Nodes page's first refresh. Immediately after it the
/// transcript's attribution flipped from BBSCBH to DRLNOD for text the BBS
/// was plainly still sending, the relay chain vanished from the header, and
/// the session picker forgot its destination — over a link still up and
/// still exchanging frames.
final class TerminalModelHolderTests: XCTestCase {

    /// Nothing yet built: there is no model to keep.
    func testTheFirstAskAlwaysBuilds() {
        XCTAssertTrue(TerminalModelBox.needsRebuild(existing: nil, wanted: "K0EPI-7"))
    }

    /// The fix: coming back to the terminal must reuse what is already there.
    func testReturningToTheSameStationKeepsTheModel() {
        XCTAssertFalse(TerminalModelBox.needsRebuild(existing: "K0EPI-7", wanted: "K0EPI-7"))
    }

    /// A different station is a different operator identity, and its
    /// sessions and relay state belong to the old one.
    func testADifferentCallsignRebuilds() {
        XCTAssertTrue(TerminalModelBox.needsRebuild(existing: "K0EPI-7", wanted: "K0EPI-1"))
    }

    /// Case is not identity. Rebuilding on a settings field being retyped in
    /// lower case would throw away a live session's state for nothing.
    func testCaseAloneIsNotADifferentStation() {
        XCTAssertFalse(TerminalModelBox.needsRebuild(existing: "K0EPI-7", wanted: "k0epi-7"))
    }
}
