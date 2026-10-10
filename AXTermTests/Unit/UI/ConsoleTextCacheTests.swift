import XCTest
@testable import AXTerm

/// A console row's text, built once and reused while nothing it depends on
/// changes. Scrolling rebuilt every row's links and underlines on each step,
/// a fifth of the main thread in a profile of the stutter (2026-10-10).
@MainActor
final class ConsoleTextCacheTests: XCTestCase {

    private let line = UUID()

    func testTheSameRowIsBuiltOnce() {
        let cache = ConsoleTextCache()
        var builds = 0
        for _ in 0..<5 {
            _ = cache.value(line: line, version: 1) { () -> String in builds += 1; return "built" }
        }
        XCTAssertEqual(builds, 1)
    }

    /// A newly heard station or a different setting can change the links.
    func testANewVersionRebuilds() {
        let cache = ConsoleTextCache()
        var builds = 0
        _ = cache.value(line: line, version: 1) { () -> String in builds += 1; return "a" }
        let second = cache.value(line: line, version: 2) { () -> String in builds += 1; return "b" }
        XCTAssertEqual(builds, 2)
        XCTAssertEqual(second, "b")
    }

    func testPruningForgetsRowsNoLongerShown() {
        let cache = ConsoleTextCache()
        let other = UUID()
        _ = cache.value(line: line, version: 1) { "a" }
        _ = cache.value(line: other, version: 1) { "b" }
        cache.prune(keeping: [other])
        var rebuilt = false
        _ = cache.value(line: line, version: 1) { () -> String in rebuilt = true; return "a" }
        XCTAssertTrue(rebuilt)
        XCTAssertEqual(cache.count, 2)
    }
}
