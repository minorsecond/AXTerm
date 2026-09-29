import XCTest
@testable import AXTerm

/// What fills the sidebar below the view list.
///
/// One rule, not a list of exceptions: whatever the frontmost page navigates
/// by. The first attempt at this only *removed* the radio context on Mail,
/// which fixed nothing visible — the folders were still a column of their
/// own, so the window opened four columns wide with one of them blank.
final class SidebarContextTests: XCTestCase {

    /// The pages the station filter actually drives. `stationFilterApplies`
    /// in ContentView names the same three, and the two must not drift: a
    /// page whose sidebar offers a filter it does not obey is worse than one
    /// offering nothing.
    func testStationFilteredPagesKeepTheRadioContext() {
        for item in [NavigationItem.terminal, .packets, .analytics] {
            XCTAssertEqual(SidebarContext.section(for: item), .radio, "\(item)")
        }
    }

    /// A "Reachable via" row *is* the Nodes page's filter — tapping it sets
    /// `nodeRouteFilter` — so the radio context is that page's navigation
    /// rather than a bystander beside it.
    func testNodeOrientedPagesKeepTheRadioContext() {
        XCTAssertEqual(SidebarContext.section(for: .routes), .radio)
        XCTAssertEqual(SidebarContext.section(for: .nodes), .radio)
    }

    func testMapIsNavigatedByLayer() {
        XCTAssertEqual(SidebarContext.section(for: .map), .mapLayers)
    }

    func testMailIsNavigatedByFolder() {
        XCTAssertEqual(SidebarContext.section(for: .mail), .mailFolders)
    }

    /// BBS used to carry a segmented picker across the top of the page — a
    /// second row of navigation inside a page that already had a column of
    /// it alongside.
    func testBBSIsNavigatedByPane() {
        XCTAssertEqual(SidebarContext.section(for: .bbs), .bbsPanes)
    }

    /// Each page-specific section belongs to exactly one page. Two would put
    /// a mailbox or a layer list somewhere it cannot act on anything.
    func testThePageSpecificSectionsAreNotShared() {
        for section in [SidebarContext.Section.mapLayers, .mailFolders, .bbsPanes] {
            let hosts = NavigationItem.allCases.filter {
                SidebarContext.section(for: $0) == section
            }
            XCTAssertEqual(hosts.count, 1, "\(section) is hosted by \(hosts)")
        }
    }

    /// Every page gets an answer, and the radio context is a choice rather
    /// than a leftover — six pages claim it deliberately.
    ///
    /// The count is a tripwire, not a fact worth asserting for its own sake.
    /// `SidebarContext.section(for:)` switches exhaustively, so a new page
    /// cannot compile without being assigned somewhere; what it *can* do is
    /// land in `.radio` because that is the nearest case to type. This makes
    /// adding a page stop here and say which navigation it actually has.
    func testEveryPageIsAccountedFor() {
        XCTAssertEqual(
            NavigationItem.allCases.count, 9,
            "A page was added or removed. Decide which navigation it has, put it in the "
                + "right list below, and update this count — do not just bump the number.")

        let radio = NavigationItem.allCases.filter {
            SidebarContext.section(for: $0) == .radio
        }
        XCTAssertEqual(
            Set(radio), [.terminal, .packets, .routes, .nodes, .analytics, .messages],
            "Messages navigates by conversation inside the page; its sidebar is the "
                + "heard-station list, which is who you start a message or a probe against.")
    }

    /// The four sections partition the pages: every page is in exactly one,
    /// and none is in two. This is the property the count above is only a
    /// proxy for, and it holds whatever pages exist.
    func testTheSectionsPartitionEveryPage() {
        let sections: [SidebarContext.Section] = [.radio, .mapLayers, .mailFolders, .bbsPanes]
        var seen: [NavigationItem] = []
        for section in sections {
            seen += NavigationItem.allCases.filter { SidebarContext.section(for: $0) == section }
        }
        XCTAssertEqual(Set(seen), Set(NavigationItem.allCases),
                       "every page belongs to one of the four sections")
        XCTAssertEqual(seen.count, NavigationItem.allCases.count,
                       "no page is claimed by two sections")
    }
}
