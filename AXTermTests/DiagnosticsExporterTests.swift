//
//  DiagnosticsExporterTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/2/26.
//

import XCTest
@testable import AXTerm

@MainActor
final class DiagnosticsExporterTests: XCTestCase {
    func testExportIncludesRequiredKeys() throws {
        let settings = makeSettings()
        let event = AppEventRecord(
            id: UUID(),
            createdAt: Date(),
            level: .info,
            category: .settings,
            message: "Retention updated",
            metadataJSON: DeterministicJSON.encodeDictionary(["retention": "1000"])
        )
        let report = DiagnosticsExporter.makeReport(settings: settings, events: [event])
        let json = DiagnosticsExporter.makeJSON(report: report)
        XCTAssertNotNil(json)

        let data = try XCTUnwrap(json?.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(object?["app"])
        XCTAssertNotNil(object?["settings"])
        let events = object?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 1)
    }

    private func makeSettings() -> AppSettingsStore {
        let suiteName = "AXTermTests-Diagnostics-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return AppSettingsStore(defaults: defaults)
    }
}
