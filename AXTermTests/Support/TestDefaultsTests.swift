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
}
