import XCTest
@testable import AXTerm

/// What fills the sidebar below the view list.
///
/// The rule is "whatever the frontmost page navigates by". The first attempt
/// at this only *removed* the radio context on Mail, which fixed nothing the
/// operator could see: the folders were still a column of their own, so the
/// window still opened four columns wide and one of them was now blank.
final class SidebarContextTests: XCTestCase {

    /// Mail navigates by folder, so the sidebar carries the folders — and
    /// carrying them is what lets the separate column go away.
    func testMailShowsItsFolders() {
        XCTAssertEqual(SidebarContext.section(for: .mail), .mailFolders)
    }

    /// BBS has no navigation column of its own; it is a single pane. Hiding
    /// the radio context there bought no space and cost the operator the
    /// stations list.
    func testBBSKeepsTheRadioContext() {
        XCTAssertEqual(SidebarContext.section(for: .bbs), .radio)
    }

    func testPagesBuiltOnReceivedTrafficKeepTheRadioContext() {
        for item in [NavigationItem.terminal, .packets, .routes, .nodes, .analytics, .map] {
            XCTAssertEqual(SidebarContext.section(for: item), .radio, "\(item)")
        }
    }

    /// Exactly one page hosts the folders. Two would mean the mailbox
    /// appeared somewhere it cannot be acted on.
    func testOnlyMailHostsTheFolders() {
        let hosts = NavigationItem.allCases.filter {
            SidebarContext.section(for: $0) == .mailFolders
        }
        XCTAssertEqual(hosts, [.mail])
    }

    /// Every page gets an answer. The switch is exhaustive by construction,
    /// so this fails to compile rather than at runtime if one is forgotten —
    /// but a new page silently inheriting `.radio` is the drift to catch.
    func testEveryPageIsAccountedFor() {
        XCTAssertFalse(NavigationItem.allCases.isEmpty)
        for item in NavigationItem.allCases {
            let section = SidebarContext.section(for: item)
            XCTAssertTrue(section == .radio || section == .mailFolders, "\(item)")
        }
    }
}
