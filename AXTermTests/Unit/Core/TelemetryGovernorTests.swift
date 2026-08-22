//
//  TelemetryGovernorTests.swift
//  AXTermTests
//
//  Deterministic tests for the Sentry flood-control and privacy-gating layer.
//

import XCTest
@testable import AXTerm

final class TelemetryGovernorTests: XCTestCase {

    // MARK: - BreadcrumbBudget

    func testErrorBreadcrumbsAreNeverDropped() {
        var budget = BreadcrumbBudget(policy: .init(windowSeconds: 30, warningPerWindow: 1, infoPerWindow: 1))
        for i in 0..<500 {
            XCTAssertEqual(budget.admit(category: "tx.session", level: .error, now: Double(i) * 0.01), .allow,
                           "error crumbs are the ones that explain failures — never dropped")
        }
    }

    func testInfoBudgetEnforcedPerWindow() {
        var budget = BreadcrumbBudget(policy: .init(windowSeconds: 30, warningPerWindow: 60, infoPerWindow: 3))
        XCTAssertEqual(budget.admit(category: "packets.insert", level: .info, now: 0), .allow)
        XCTAssertEqual(budget.admit(category: "packets.insert", level: .info, now: 1), .allow)
        XCTAssertEqual(budget.admit(category: "packets.insert", level: .info, now: 2), .allow)
        XCTAssertEqual(budget.admit(category: "packets.insert", level: .info, now: 3), .drop)
        XCTAssertEqual(budget.admit(category: "packets.insert", level: .info, now: 4), .drop)
    }

    func testWindowRolloverReportsSuppressedCount() {
        var budget = BreadcrumbBudget(policy: .init(windowSeconds: 30, warningPerWindow: 60, infoPerWindow: 1))
        XCTAssertEqual(budget.admit(category: "c", level: .info, now: 0), .allow)
        XCTAssertEqual(budget.admit(category: "c", level: .info, now: 1), .drop)
        XCTAssertEqual(budget.admit(category: "c", level: .info, now: 2), .drop)
        // New window: the first admitted crumb carries the drop count so
        // suppression is never mistaken for inactivity.
        XCTAssertEqual(budget.admit(category: "c", level: .info, now: 31), .allowAfterSuppressing(2))
        XCTAssertEqual(budget.admit(category: "c", level: .info, now: 32), .drop)
    }

    func testWarningAndInfoBudgetsAreIndependent() {
        var budget = BreadcrumbBudget(policy: .init(windowSeconds: 30, warningPerWindow: 2, infoPerWindow: 1))
        XCTAssertEqual(budget.admit(category: "c", level: .info, now: 0), .allow)
        XCTAssertEqual(budget.admit(category: "c", level: .info, now: 1), .drop)
        // A debug/info flood must not starve warnings in the same category.
        XCTAssertEqual(budget.admit(category: "c", level: .warning, now: 2), .allow)
        XCTAssertEqual(budget.admit(category: "c", level: .warning, now: 3), .allow)
        XCTAssertEqual(budget.admit(category: "c", level: .warning, now: 4), .drop)
    }

    func testCategoriesAreIndependent() {
        var budget = BreadcrumbBudget(policy: .init(windowSeconds: 30, warningPerWindow: 60, infoPerWindow: 1))
        XCTAssertEqual(budget.admit(category: "a", level: .info, now: 0), .allow)
        XCTAssertEqual(budget.admit(category: "a", level: .info, now: 1), .drop)
        XCTAssertEqual(budget.admit(category: "b", level: .info, now: 2), .allow,
                       "one noisy category must not exhaust another's budget")
    }

    // MARK: - TelemetryContentRedactor

    func testContentKeysAreRedacted() {
        let data: [String: Any] = [
            "preview": "Hello Ross. Latest Message is 54245",
            "text": "private mail body",
            "hex": "C00096846AB2",
            "ascii": "Welcome to YZBBPQ",
            "prefixHex": "57656C63",
            "prefixAscii": "Welcome",
            "infoHex": "AABBCC"
        ]
        let redacted = TelemetryContentRedactor.redact(data, allowContents: false)!
        for key in data.keys {
            XCTAssertEqual(redacted[key] as? String, TelemetryContentRedactor.placeholder,
                           "\(key) carries over-the-air content and must not leave the machine")
        }
    }

    func testMetadataKeysPassThrough() {
        let data: [String: Any] = [
            "peer": "KB5YZB-7",
            "ns": 4, "nr": 5,
            "textLength": 60,
            "payloadLen": 128,
            "byteCount": 151,
            "rto": "24.0s",
            "via": "DRLNOD"
        ]
        let redacted = TelemetryContentRedactor.redact(data, allowContents: false)!
        for (key, value) in data {
            XCTAssertEqual(String(describing: redacted[key]!), String(describing: value),
                           "\(key) is diagnostic metadata and must survive redaction")
        }
    }

    func testOperatorOptInPassesContentsThrough() {
        let data: [String: Any] = ["preview": "hello world"]
        let passed = TelemetryContentRedactor.redact(data, allowContents: true)!
        XCTAssertEqual(passed["preview"] as? String, "hello world",
                       "the explicit user setting is the only thing that allows content out")
    }

    func testNilDataPassesThrough() {
        XCTAssertNil(TelemetryContentRedactor.redact(nil, allowContents: false))
    }

    // MARK: - EventThrottle

    func testFirstEventAlwaysShips() {
        var throttle = EventThrottle(windowSeconds: 60)
        XCTAssertEqual(throttle.admit(key: "decode.ax25", now: 0), .allow)
    }

    func testRepeatsWithinWindowAreSuppressedThenCounted() {
        var throttle = EventThrottle(windowSeconds: 60)
        XCTAssertEqual(throttle.admit(key: "k", now: 0), .allow)
        for t in 1...50 {
            XCTAssertEqual(throttle.admit(key: "k", now: Double(t)), .drop,
                           "a garbled stream must become one issue, not a quota incident")
        }
        XCTAssertEqual(throttle.admit(key: "k", now: 61), .allowAfterSuppressing(50))
    }

    func testDistinctKeysAreIndependent() {
        var throttle = EventThrottle(windowSeconds: 60)
        XCTAssertEqual(throttle.admit(key: "a", now: 0), .allow)
        XCTAssertEqual(throttle.admit(key: "a", now: 1), .drop)
        XCTAssertEqual(throttle.admit(key: "b", now: 2), .allow)
    }

    // MARK: - AX.25 decode failure reasons

    func testDecodeFailureReasonsAreDifferentiated() {
        XCTAssertEqual(AX25.decodeFailureReason(ax25: Data([0x01, 0x02])),
                       "frame shorter than 15-byte minimum")

        // 15 bytes of zeros: destination callsign decodes to empty → invalid.
        XCTAssertEqual(AX25.decodeFailureReason(ax25: Data(repeating: 0x00, count: 15)),
                       "invalid destination address")

        // Valid destination, garbage source (zeroed callsign bytes).
        var badSource = Data()
        for ch in "KB5YZB" { badSource.append(UInt8(ch.asciiValue! << 1)) }
        badSource.append(0x60)                          // dest SSID byte
        badSource.append(contentsOf: Data(repeating: 0x00, count: 7))  // source
        badSource.append(0x3F)                          // control
        XCTAssertEqual(AX25.decodeFailureReason(ax25: badSource), "invalid source address")
    }
}
