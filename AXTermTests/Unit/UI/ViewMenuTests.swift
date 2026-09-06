import XCTest
@testable import AXTerm

/// The View menu and the sidebar list the same destinations, numbered the
/// same way — and there is only one View menu.
///
/// Both halves of that failed at once. `CommandMenu("View")` does not merge
/// with the View menu SwiftUI already provides, so the menu bar read
/// "File Edit View Connection View Window Help"; and the custom menu listed
/// five of the eight destinations, leaving Nodes, Map and BBS unreachable
/// from the keyboard while numbering Analytics ⌘4 when it sits fifth.
final class ViewMenuTests: XCTestCase {

    func testEveryDestinationIsReachableFromTheKeyboard() {
        let shortcuts = NavigationItem.allCases.map(\.menuShortcut)
        XCTAssertEqual(Set(shortcuts).count, NavigationItem.allCases.count,
                       "two destinations share a number: \(shortcuts)")
    }

    /// The numbers are only useful if they match what the operator is
    /// looking at.
    func testTheNumbersFollowSidebarOrder() {
        for (index, item) in NavigationItem.allCases.enumerated() {
            XCTAssertEqual(item.menuShortcut, Character("\(index + 1)"),
                           "\(item.rawValue) is #\(index + 1) in the sidebar")
        }
    }

    /// A second `CommandMenu` with a standard menu's name adds a duplicate to
    /// the menu bar rather than extending the original. The View menu is the
    /// one that bit; File, Edit, Window and Help would behave the same way.
    func testNoCommandMenuShadowsAStandardMenu() throws {
        let commands = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UI
            .deletingLastPathComponent()   // Unit
            .deletingLastPathComponent()   // AXTermTests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("AXTerm/AXTermCommands.swift")

        let raw = try String(contentsOf: commands, encoding: .utf8)
        // A scan that reads nothing passes for the wrong reason.
        XCTAssertGreaterThan(raw.count, 500, "did not read AXTermCommands.swift")

        // Comments explain the trap by naming it, so scan code only —
        // otherwise the guard fires on the sentence describing the guard.
        let source = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")

        for standard in ["File", "Edit", "View", "Window", "Help"] {
            XCTAssertFalse(source.contains("CommandMenu(\"\(standard)\")"),
                           "CommandMenu(\"\(standard)\") adds a second \(standard) menu; "
                           + "extend the existing one with CommandGroup instead")
        }
    }
}
