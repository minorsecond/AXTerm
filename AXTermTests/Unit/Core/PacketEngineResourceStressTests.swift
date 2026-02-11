//
//  PacketEngineResourceStressTests.swift
//  AXTermTests
//
//  Created by Codex on 2/11/26.
//

import Darwin
import XCTest
@testable import AXTerm

@MainActor
final class PacketEngineResourceStressTests: XCTestCase {
    func testLongRunPacketIngressKeepsRetainedCollectionsBounded() async throws {
        try requireStressEnabled()
        let maxPackets = 2_000
        let maxConsoleLines = 2_000
        let maxRawChunks = 500
        let totalPackets = 45_000
        let stationCount = 64

        let engine = PacketEngine(
            maxPackets: maxPackets,
            maxConsoleLines: maxConsoleLines,
            maxRawChunks: maxRawChunks,
            settings: makeSettings(persistHistory: false)
        )

        let base = Date()
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<totalPackets {
            engine.handleIncomingPacket(makePacket(index: i, base: base, stationCount: stationCount))
            if i % 1_000 == 0 {
                await Task.yield()
            }
            if i % 2_000 == 0 {
                XCTAssertLessThanOrEqual(engine.packets.count, maxPackets)
                XCTAssertLessThanOrEqual(engine.consoleLines.count, maxConsoleLines)
            }
        }

        XCTAssertEqual(engine.packets.count, maxPackets, "In-memory packet list should stay capped.")
        XCTAssertEqual(engine.consoleLines.count, maxConsoleLines, "Console packet lines should stay capped.")
        XCTAssertLessThanOrEqual(engine.stations.count, stationCount, "Station tracker should only retain unique station identities.")
        XCTAssertTrue(engine.rawChunks.isEmpty, "Raw chunks should remain empty when only packet ingest API is exercised.")
        addStressReportAttachment(
            name: "Bounded Collections Report",
            lines: [
                "packets_ingested=\(totalPackets)",
                "elapsed_s=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - start))",
                "packets_count=\(engine.packets.count)",
                "console_lines_count=\(engine.consoleLines.count)",
                "stations_count=\(engine.stations.count)"
            ]
        )
    }

    func testLongRunPacketIngressMemoryGrowthStabilizesAfterWarmup() async throws {
        try requireStressEnabled()
        let warmupPackets = 20_000
        let sustainedPackets = 20_000
        let stationCount = 64

        let engine = PacketEngine(
            maxPackets: 2_000,
            maxConsoleLines: 2_000,
            maxRawChunks: 500,
            settings: makeSettings(persistHistory: false)
        )

        let base = Date()
        for i in 0..<warmupPackets {
            engine.handleIncomingPacket(makePacket(index: i, base: base, stationCount: stationCount))
            if i % 1_000 == 0 {
                await Task.yield()
            }
        }

        let before = residentMemoryBytes()
        guard before > 0 else {
            throw XCTSkip("Could not read resident memory on this platform.")
        }

        for i in warmupPackets..<(warmupPackets + sustainedPackets) {
            engine.handleIncomingPacket(makePacket(index: i, base: base, stationCount: stationCount))
            if i % 1_000 == 0 {
                await Task.yield()
            }
        }

        let after = residentMemoryBytes()
        let deltaBytes = after > before ? after - before : 0
        let deltaMB = Double(deltaBytes) / 1_048_576.0

        XCTAssertLessThanOrEqual(
            deltaMB,
            40.0,
            "Resident memory should remain near steady-state after caps are reached; observed +\(String(format: "%.2f", deltaMB)) MB."
        )
        addStressReportAttachment(
            name: "Memory Stabilization Report",
            lines: [
                "warmup_packets=\(warmupPackets)",
                "sustained_packets=\(sustainedPackets)",
                "resident_before_mb=\(String(format: "%.2f", Double(before) / 1_048_576.0))",
                "resident_after_mb=\(String(format: "%.2f", Double(after) / 1_048_576.0))",
                "resident_delta_mb=\(String(format: "%.2f", deltaMB))"
            ]
        )
    }

    func testPostSoakFilteringRemainsResponsive() async throws {
        try requireStressEnabled()
        let ingestPackets = 25_000
        let filterIterations = 200
        let stationCount = 64

        let engine = PacketEngine(
            maxPackets: 2_000,
            maxConsoleLines: 2_000,
            maxRawChunks: 500,
            settings: makeSettings(persistHistory: false)
        )

        let base = Date()
        for i in 0..<ingestPackets {
            engine.handleIncomingPacket(makePacket(index: i, base: base, stationCount: stationCount))
            if i % 1_000 == 0 {
                await Task.yield()
            }
        }

        let filters = PacketFilters()
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<filterIterations {
            let query = (i % 3 == 0) ? "N00" : (i % 3 == 1 ? "D00" : "")
            _ = engine.filteredPackets(search: query, filters: filters, stationCall: nil)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(
            elapsed,
            3.0,
            "Filtering should stay responsive after heavy ingress. Observed \(String(format: "%.3f", elapsed))s for \(filterIterations) runs."
        )
        addStressReportAttachment(
            name: "Filtering Responsiveness Report",
            lines: [
                "ingest_packets=\(ingestPackets)",
                "filter_iterations=\(filterIterations)",
                "elapsed_s=\(String(format: "%.3f", elapsed))"
            ]
        )
    }

    private func makeSettings(persistHistory: Bool) -> AppSettingsStore {
        let suiteName = "AXTermTests-Resource-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.set(persistHistory, forKey: AppSettingsStore.persistKey)
        defaults.set("", forKey: AppSettingsStore.myCallsignKey)
        return AppSettingsStore(defaults: defaults)
    }

    private func makePacket(index: Int, base: Date, stationCount: Int) -> Packet {
        let fromIndex = index % stationCount
        let toIndex = (index * 7 + 3) % stationCount
        return Packet(
            timestamp: base.addingTimeInterval(Double(index) * 0.01),
            from: AX25Address(call: String(format: "N%03dA", fromIndex)),
            to: AX25Address(call: String(format: "D%03dB", toIndex)),
            frameType: .ui,
            control: 0x03,
            info: Data("PING-\(index % 128)".utf8),
            rawAx25: Data([0xC0, 0x00, 0xF0, UInt8(index & 0xFF)])
        )
    }

    private func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)

        let status: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), integerPointer, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private func addStressReportAttachment(name: String, lines: [String]) {
        let markdown = "# \(name)\n" + lines.map { "- \($0)" }.joined(separator: "\n")
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(string: markdown)
            attachment.name = "\(name).md"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    private func requireStressEnabled() throws {
        let env = ProcessInfo.processInfo.environment
        let isCI = (env["CI"] == "1") || (env["CI"]?.lowercased() == "true") || env["CI_XCODE_CLOUD"] == "1"
        let explicit = env["AXTERM_RUN_STRESS_TESTS"] == "1"

        if isCI && !explicit {
            throw XCTSkip("Stress/resource tests are skipped in CI unless AXTERM_RUN_STRESS_TESTS=1.")
        }
    }
}
