import XCTest
@testable import AXTerm

/// What belongs in the primary sidebar for the page in front.
///
/// Mail and BBS bring their own navigation column — folders, boards — so the
/// operator was looking at two sidebars before the content started: Views,
/// then Reachable via nodes, then Stations (30), then Folders, then the
/// message list. Nothing in the radio sections shapes those pages.
final class SidebarContextTests: XCTestCase {

    /// The pages the radio context serves: what can be reached, what is
    /// live, who has been heard.
    func testRadioPagesKeepTheirContext() {
        for item in [NavigationItem.terminal, .packets, .routes, .nodes, .analytics, .map] {
            XCTAssertTrue(SidebarContext.showsRadioSections(for: item),
                          "\(item.rawValue) is a radio page")
        }
    }

    /// The pages that bring their own second column.
    func testPagesWithTheirOwnNavigationDropIt() {
        XCTAssertFalse(SidebarContext.showsRadioSections(for: .mail))
        XCTAssertFalse(SidebarContext.showsRadioSections(for: .bbs))
    }

    /// Every page must be decided deliberately: a new one silently keeping
    /// or losing the sidebar is how this drifts.
    func testEveryPageHasAnAnswer() {
        for item in NavigationItem.allCases {
            _ = SidebarContext.showsRadioSections(for: item)
        }
    }
}
