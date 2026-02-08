//
//  TelemetryTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2026-02-14.
//

import XCTest
@testable import AXTerm

final class TelemetryTests: XCTestCase {
    private var originalBackend: TelemetryBackend?

    override func setUp() {
        super.setUp()
        originalBackend = Telemetry.backendForTesting
    }

    override func tearDown() {
        if let originalBackend {
            Telemetry.setBackend(originalBackend)
        }
        super.tearDown()
    }

    func testMeasureReturnsValue() throws {
        Telemetry.setBackend(FakeTelemetryBackend(isEnabled: true))
        let value = try Telemetry.measure(name: "value") { 42 }
        XCTAssertEqual(value, 42)
    }

    func testMeasureRethrows() {
        Telemetry.setBackend(FakeTelemetryBackend(isEnabled: true))
        XCTAssertThrowsError(try Telemetry.measure(name: "error") {
            throw SampleError()
        })
    }

    func testBreadcrumbAndCaptureNoCrashWhenDisabled() {
        Telemetry.setBackend(NoOpTelemetryBackend())
        Telemetry.breadcrumb(category: "test", message: "breadcrumb", data: nil, level: .info)
        Telemetry.capture(error: SampleError(), message: "error", data: ["key": "value"])
        Telemetry.capture(message: "message", data: ["key": "value"])
    }
}

private struct SampleError: Error {}

private final class FakeTelemetryBackend: TelemetryBackend {
    let isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func addBreadcrumb(category _: String, message _: String, data _: [String: Any]?, level _: TelemetryLevel) {}

    func startSpan(name _: String, operation _: String?, data _: [String: Any]?) -> TelemetrySpanToken? {
        NSObject()
    }

    func updateSpan(_ span: TelemetrySpanToken?, data: [String: Any]) {}

    func finishSpan(_ span: TelemetrySpanToken?, status: TelemetrySpanStatus) {}

    func capture(error _: Error, message _: String, data _: [String: Any]?) {}

    func capture(message _: String, data _: [String: Any]?) {}
}
