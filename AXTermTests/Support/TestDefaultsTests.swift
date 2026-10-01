//
//  TestDefaultsTests.swift
//  AXTermTests
//
//  The helper every test uses for UserDefaults has to behave like a real
//  suite and keep its plist out of Library/Preferences.
//

import XCTest

final class TestDefaultsTests: XCTestCase {

    private var preferencesDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)
    }

    func testSuiteRoundTripsAndReopensByName() {
        let name = TestDefaults.name("roundtrip")
        let first = UserDefaults(suiteName: name)!
        first.set("value", forKey: "key")
        first.set(7, forKey: "count")

        let reopened = UserDefaults(suiteName: name)!
        XCTAssertEqual(reopened.string(forKey: "key"), "value")
        XCTAssertEqual(reopened.integer(forKey: "count"), 7)
        XCTAssertEqual(first.persistentDomain(forName: name)?["key"] as? String, "value")
    }

    func testEachSuiteStartsEmpty() {
        let a = TestDefaults.make("isolation")
        a.set(true, forKey: "flag")
        let b = TestDefaults.make("isolation")
        XCTAssertNil(b.object(forKey: "flag"))
    }

    func testSuiteLivesOutsidePreferences() {
        let name = TestDefaults.name("location")
        XCTAssertTrue(name.hasPrefix("/"), "suite should be named by absolute path")
        XCTAssertFalse(name.hasPrefix(preferencesDirectory.path))

        let defaults = UserDefaults(suiteName: name)!
        defaults.set("x", forKey: "k")
        defaults.synchronize()

        let leaked = (try? FileManager.default.contentsOfDirectory(atPath: preferencesDirectory.path))?
            .filter { $0.contains((name as NSString).lastPathComponent) } ?? []
        XCTAssertEqual(leaked, [])
    }

    /// Every test gets its suites from TestDefaults. A suite named by hand,
    /// `UserDefaults(suiteName: "SomeTests.\(UUID())")`, becomes a plist in
    /// Library/Preferences that nothing removes: on 2026-10-01 two test
    /// classes doing that had left 742 of them since the 2026-09-30 fix.
    func testNoTestNamesItsOwnSuite() throws {
        let testsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Support
            .deletingLastPathComponent()      // AXTermTests
        let handNamed = try NSRegularExpression(
            pattern: #"UserDefaults\(suiteName:\s*"|suiteName\s*=\s*"[^"]"#)
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", file.lastPathComponent != "TestDefaults.swift",
                  let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (number, line) in source.components(separatedBy: "\n").enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                if handNamed.firstMatch(in: line, range: range) != nil {
                    offenders.append("\(file.lastPathComponent):\(number + 1)")
                }
            }
        }
        XCTAssertGreaterThan(Self.countSwiftFiles(in: testsRoot), 100, "the scan has to find the test sources")
        XCTAssertEqual(offenders, [], "use TestDefaults.make or TestDefaults.name for these suites")
    }

    private static func countSwiftFiles(in root: URL) -> Int {
        var count = 0
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            if file.pathExtension == "swift" { count += 1 }
        }
        return count
    }
}
