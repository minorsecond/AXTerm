//
//  TestDefaults.swift
//  AXTermTests
//
//  Throwaway UserDefaults suites for tests.
//
//  A suite opened as `UserDefaults(suiteName: "SomeTests-<UUID>")` becomes
//  its own plist in the app container's Library/Preferences, and nothing
//  ever deletes it. `removePersistentDomain(forName:)` only empties the
//  domain: cfprefsd writes the empty plist back a few seconds later, even
//  when the test unlinks the file straight after. By 2026-09-30 that
//  directory held about 35,000 of them.
//
//  CFPreferences also takes an absolute path as a suite name and uses it as
//  the plist's location. Every suite made here is named that way, under a
//  per-process directory in the container's tmp, so none of them go near
//  Library/Preferences. The directory is removed when the test bundle
//  finishes; directories left by a run that crashed or was killed are swept
//  the next time a suite is made.
//

import Foundation
import XCTest

enum TestDefaults {

    /// A fresh, empty suite. `label` only makes the file easier to spot.
    static func make(_ label: String = "suite") -> UserDefaults {
        let suiteName = name(label)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("UserDefaults refused the test suite \(suiteName)")
        }
        return defaults
    }

    /// A fresh suite name, for tests that reopen the same suite or read its
    /// persistent domain. Open it with `UserDefaults(suiteName:)` as usual;
    /// it is cleaned up with the rest.
    static func name(_ label: String = "suite") -> String {
        TestDefaultsDirectory.shared.newSuiteName(label)
    }
}

private final class TestDefaultsDirectory: NSObject, XCTestObservation {

    static let shared = TestDefaultsDirectory()

    private static let pidPrefix = "pid"

    private let root: URL
    private let directory: URL
    private let lock = NSLock()
    private var suiteNames: [String] = []

    private override init() {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AXTermTestDefaults", isDirectory: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        directory = root.appendingPathComponent("\(Self.pidPrefix)\(pid)", isDirectory: true)
        super.init()
        sweepFinishedProcesses()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if Thread.isMainThread {
            XCTestObservationCenter.shared.addTestObserver(self)
        } else {
            DispatchQueue.main.async { XCTestObservationCenter.shared.addTestObserver(self) }
        }
    }

    func newSuiteName(_ label: String) -> String {
        let safeLabel = label.replacingOccurrences(of: "/", with: "-")
        let name = directory
            .appendingPathComponent("\(safeLabel)-\(UUID().uuidString)")
            .path
        lock.lock()
        suiteNames.append(name)
        lock.unlock()
        return name
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        lock.lock()
        let names = suiteNames
        suiteNames.removeAll()
        lock.unlock()
        // Empty each domain first so cfprefsd drops what it cached. The
        // write that follows lands in a directory that no longer exists,
        // and cfprefsd does not recreate it.
        for name in names {
            UserDefaults().removePersistentDomain(forName: name)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Remove directories whose test process is gone. A parallel run has
    /// several workers alive at once, each with its own directory, so only
    /// a pid that no longer exists (ESRCH) is treated as finished.
    private func sweepFinishedProcesses() {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(Self.pidPrefix),
                  let pid = Int32(name.dropFirst(Self.pidPrefix.count)),
                  pid != ProcessInfo.processInfo.processIdentifier else { continue }
            guard kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
