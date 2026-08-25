import XCTest
@testable import AXTerm

/// The rules behind the main window's single sheet.
///
/// Written because the bug they prevent is invisible in code review: two
/// `.sheet` modifiers on one view compile, run, and quietly present only one
/// of them. The identity page opened once and then refused to reappear, and
/// nothing about the call site looked wrong.
@MainActor
final class RootSheetRouteTests: XCTestCase {

    private let packet = UUID()
    private let peek = NodeProfileCoordinator.Presentation.peek("W0ARP-10")
    private let page = NodeProfileCoordinator.Presentation.page("W0ARP-10")

    func testNothingSetShowsNothing() {
        XCTAssertNil(RootSheetRoute.current(inspector: nil, profile: nil))
    }

    func testEitherSourceAloneShows() {
        XCTAssertEqual(RootSheetRoute.current(inspector: packet, profile: nil),
                       .inspector(packet))
        XCTAssertEqual(RootSheetRoute.current(inspector: nil, profile: peek),
                       .profile(peek))
    }

    /// Raising one sheet puts the other away, so the two can never both be
    /// set — which is what made them fight for the slot.
    func testRaisingOneClearsTheOther() {
        let toProfile = RootSheetRoute.apply(.profile(peek))
        XCTAssertNil(toProfile.inspector)
        XCTAssertEqual(toProfile.profile, peek)

        let toInspector = RootSheetRoute.apply(.inspector(packet))
        XCTAssertEqual(toInspector.inspector, packet)
        XCTAssertNil(toInspector.profile)
    }

    /// The actual defect: dismissing must clear *both* sources. Leaving one
    /// set means the next request writes the same value, SwiftUI sees no
    /// change, and the sheet never reopens.
    func testDismissalClearsBothSources() {
        let cleared = RootSheetRoute.apply(nil)
        XCTAssertNil(cleared.inspector)
        XCTAssertNil(cleared.profile)
    }

    /// Reopening the same station after a dismissal is the exact sequence
    /// that used to fail.
    func testTheSameStationCanBeReopenedAfterDismissal() {
        var profile = RootSheetRoute.apply(.profile(peek)).profile
        XCTAssertNotNil(RootSheetRoute.current(inspector: nil, profile: profile))

        profile = RootSheetRoute.apply(nil).profile
        XCTAssertNil(RootSheetRoute.current(inspector: nil, profile: profile))

        profile = RootSheetRoute.apply(.profile(peek)).profile
        XCTAssertEqual(RootSheetRoute.current(inspector: nil, profile: profile),
                       .profile(peek))
    }

    /// Promoting a peek to a full page is a change, not a no-op — the ids
    /// must differ or SwiftUI will not re-present.
    func testAPeekAndAPageAreDistinctRoutes() {
        XCTAssertNotEqual(RootSheetRoute.profile(peek).id,
                          RootSheetRoute.profile(page).id)
    }

    func testAnInspectorAndAProfileNeverShareAnIdentity() {
        XCTAssertNotEqual(RootSheetRoute.inspector(packet).id,
                          RootSheetRoute.profile(peek).id)
    }
}
