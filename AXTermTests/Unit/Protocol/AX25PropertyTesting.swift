//
//  AX25PropertyTesting.swift
//  AXTermTests
//
//  Shared machinery for the seeded property tests (CLAUDE.md §13: property
//  tests for malformed and replayed packets, determinism tests).
//
//  Every case runs from its own 64-bit seed, derived from the property name
//  and the case index, so a run is reproducible and a failure names the
//  seed that produced it.
//
//  Environment (pass through xcodebuild with the TEST_RUNNER_ prefix, e.g.
//  `TEST_RUNNER_AXTERM_FUZZ_ITERATIONS=20000 xcodebuild test ...`):
//
//    AXTERM_FUZZ_ITERATIONS  cases per property instead of the default
//                            (the soak mode; defaults keep the suite fast)
//    AXTERM_FUZZ_SEED        run exactly one case from this seed (hex with
//                            0x, or decimal) to replay a reported failure
//    AXTERM_FUZZ_BASE        mixes into every derived seed, for a fresh
//                            sweep without changing code
//    AXTERM_FUZZ_VERBOSE     print each seed before its case runs, so a
//                            trap inside the app still leaves the seed in
//                            the log
//

import Foundation
import XCTest
@testable import AXTerm

/// SplitMix64. Small, fast and identical on every platform, which is all a
/// reproducible fuzzer needs.
nonisolated struct PropertyRNG: RandomNumberGenerator {
    private(set) var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }

    /// Uniform in 0..<bound; 0 when bound is not positive.
    mutating func int(_ bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(next() % UInt64(bound))
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + int(range.upperBound - range.lowerBound + 1)
    }

    /// True with probability `p`.
    mutating func chance(_ p: Double) -> Bool {
        unit() < p
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }

    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }

    mutating func bytes(_ count: Int) -> Data {
        var data = Data(capacity: max(0, count))
        for _ in 0..<max(0, count) { data.append(byte()) }
        return data
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[int(items.count)]
    }
}

nonisolated enum PropertyRun {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// The soak count, when one was asked for.
    static var soakIterations: Int? {
        environment["AXTERM_FUZZ_ITERATIONS"].flatMap { Int($0) }.map { max(1, $0) }
    }

    static var replaySeed: UInt64? {
        environment["AXTERM_FUZZ_SEED"].flatMap(parseSeed)
    }

    static var baseSeed: UInt64 {
        environment["AXTERM_FUZZ_BASE"].flatMap(parseSeed) ?? 0
    }

    static var verbose: Bool { environment["AXTERM_FUZZ_VERBOSE"] != nil }

    static func parseSeed(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasPrefix("0x") { return UInt64(trimmed.dropFirst(2), radix: 16) }
        return UInt64(trimmed)
    }

    /// Cases to run for a property: the soak count if set, else the default.
    static func caseCount(default count: Int) -> Int {
        soakIterations ?? count
    }

    /// The seed for case `index` of `property`. FNV-1a over the name keeps
    /// two properties from sharing a seed sequence.
    static func seed(property: String, index: Int) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in property.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        var mixer = PropertyRNG(seed: hash ^ baseSeed ^ (UInt64(index) &* 0xD1B5_4A32_D192_ED03))
        return mixer.next()
    }

    static func hex(_ seed: UInt64) -> String { String(format: "0x%016llX", seed) }
}

/// Violations collected during one case. A case passes when it records none.
final class PropertyViolations {
    private(set) var messages: [String] = []
    /// Stop collecting past this many; the first few say what went wrong.
    let limit = 8

    var isEmpty: Bool { messages.isEmpty }

    func record(_ message: @autoclosure () -> String) {
        guard messages.count < limit else { return }
        messages.append(message())
    }

    func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { record(message()) }
    }
}

extension XCTestCase {
    /// Runs `body` once per seed. Stops at the first failing case and fails
    /// the test with the seed, the case index and the violations, so the
    /// case can be replayed with AXTERM_FUZZ_SEED.
    ///
    /// Returns the number of cases run, for tests that report coverage.
    @MainActor
    @discardableResult
    func checkProperty(
        _ name: String,
        cases defaultCases: Int,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: (_ rng: inout PropertyRNG, _ violations: PropertyViolations) throws -> Void
    ) rethrows -> Int {
        let seeds: [(index: Int, seed: UInt64)]
        if let replay = PropertyRun.replaySeed {
            seeds = [(0, replay)]
        } else {
            let count = PropertyRun.caseCount(default: defaultCases)
            seeds = (0..<count).map { ($0, PropertyRun.seed(property: name, index: $0)) }
        }
        for (index, seed) in seeds {
            if PropertyRun.verbose { print("[property] \(name) case \(index) seed=\(PropertyRun.hex(seed))") }
            var rng = PropertyRNG(seed: seed)
            let violations = PropertyViolations()
            try body(&rng, violations)
            if !violations.isEmpty {
                XCTFail("""
                    Property '\(name)' failed at case \(index), seed=\(PropertyRun.hex(seed)) \
                    (replay with AXTERM_FUZZ_SEED=\(PropertyRun.hex(seed))):
                    \(violations.messages.map { "  - " + $0 }.joined(separator: "\n"))
                    """, file: file, line: line)
                return index + 1
            }
        }
        if PropertyRun.soakIterations != nil {
            print("[property] \(name): \(seeds.count) cases passed (base=\(PropertyRun.hex(PropertyRun.baseSeed)))")
        }
        return seeds.count
    }
}
