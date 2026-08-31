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
    /// than a leftover — five pages claim it deliberately.
    func testEveryPageIsAccountedFor() {
        XCTAssertEqual(NavigationItem.allCases.count, 8)
        let radio = NavigationItem.allCases.filter {
            SidebarContext.section(for: $0) == .radio
        }
        XCTAssertEqual(Set(radio), [.terminal, .packets, .routes, .nodes, .analytics])
    }
}
