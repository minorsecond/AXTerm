import XCTest

/// One search field per window.
///
/// Field report, 2026-08-31: opening the new History tab took the app down.
///
///     NSToolbar 0x600003a40900 already contains an item with the identifier
///     com.apple.SwiftUI.search. Duplicate items of this type are not allowed.
///
/// `.searchable` installs a toolbar item with a fixed identifier, so a second
/// one anywhere inside the same window is an AppKit assertion failure rather
/// than a warning or a layout oddity. The main window has owned that field
/// since the universal search was built; the history browser added another
/// without knowing.
///
/// A source check because the failure is structural rather than behavioural:
/// no unit test can construct a window, and the UI tests that could are not
/// currently runnable.
final class ToolbarUniquenessTests: XCTestCase {

    /// Every macOS view that installs a search field, by file.
    ///
    /// Only ContentView may, because it is the window. Anything inside it
    /// needs an ordinary text field instead.
    func testOnlyTheWindowInstallsASearchField() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UI
            .deletingLastPathComponent()   // Unit
            .deletingLastPathComponent()   // AXTermTests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("AXTerm")

        // A source scan that finds no source passes for the wrong reason.
        // The first version of this test walked up one directory too few,
        // enumerated a path that does not exist, and reported success while
        // checking nothing at all — the same shape of green-but-empty result
        // that let an unreachable recorder ship earlier today.
        var scanned = 0

        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: root,
                                                   includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            // iOS screens each own a NavigationStack of their own, so a
            // search field there is not in this window's toolbar.
            guard !url.path.contains("/iOS/") else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            // The modifier, not the word in a comment.
            guard text.contains(".searchable(") else { continue }
            let name = url.lastPathComponent
            if name != "ContentView.swift" { offenders.append(name) }
        }

        XCTAssertGreaterThan(scanned, 100,
                             "the scan found almost no source; it is checking nothing")
        XCTAssertEqual(offenders, [],
                       "only the window may install a search field; these also do: "
                       + offenders.joined(separator: ", "))
    }
}
