//
//  NetRomSQLiteRoutingContractsTests.swift
//  AXTermTests
//
//  Deterministic routing contracts against a sqlite snapshot:
//  - Shift timestamps into a synthetic "now" so recency windows stay stable over time.
//  - Verify replay determinism for neighbors/routes/link stats.
//  - Verify routes-page mode semantics and ignore-list propagation on real data.
//

import XCTest
import GRDB
@testable import AXTerm

@MainActor
final class NetRomSQLiteRoutingContractsTests: XCTestCase {

    private let localCallsign = "K0EPI"

    func testShiftedSQLiteReplayIsDeterministicAcrossIntegrations() throws {
        let packets = try loadSQLiteSnapshotPackets()
        guard !packets.isEmpty else {
            throw XCTSkip("No packets in sqlite snapshot")
        }

        let syntheticNow = makeDate(year: 2026, month: 2, day: 11, hour: 12, minute: 0, second: 0)
        let shiftedPackets = shiftPacketsToReferenceNow(packets, referenceNow: syntheticNow)
            .sorted { $0.timestamp < $1.timestamp }

        let first = replay(shiftedPackets)
        let second = replay(shiftedPackets)

        XCTAssertFalse(first.neighbors.isEmpty, "Expected at least one neighbor from shifted replay")
        XCTAssertEqual(fingerprint(of: first.neighbors), fingerprint(of: second.neighbors), "Neighbor replay should be deterministic")
        XCTAssertEqual(fingerprint(of: first.routes), fingerprint(of: second.routes), "Route replay should be deterministic")
        XCTAssertEqual(fingerprint(of: first.linkStats), fingerprint(of: second.linkStats), "Link-stat replay should be deterministic")

        for mode in [NetRomRoutingMode.classic, .inference, .hybrid] {
            XCTAssertEqual(
                fingerprint(of: first.integration.currentNeighbors(forMode: mode)),
                fingerprint(of: second.integration.currentNeighbors(forMode: mode)),
                "Mode-filtered neighbors should be deterministic for \(String(describing: mode))"
            )
            XCTAssertEqual(
                fingerprint(of: first.integration.currentRoutes(forMode: mode)),
                fingerprint(of: second.integration.currentRoutes(forMode: mode)),
                "Mode-filtered routes should be deterministic for \(String(describing: mode))"
            )
            XCTAssertEqual(
                fingerprint(of: first.integration.exportLinkStats(forMode: mode)),
                fingerprint(of: second.integration.exportLinkStats(forMode: mode)),
                "Mode-filtered link stats should be deterministic for \(String(describing: mode))"
            )
        }
    }

    func testShiftedSQLiteRoutesPageModeAndIgnoreContracts() throws {
        let packets = try loadSQLiteSnapshotPackets()
        guard !packets.isEmpty else {
            throw XCTSkip("No packets in sqlite snapshot")
        }

        let syntheticNow = makeDate(year: 2026, month: 2, day: 11, hour: 12, minute: 0, second: 0)
        let shiftedPackets = shiftPacketsToReferenceNow(packets, referenceNow: syntheticNow)
            .sorted { $0.timestamp < $1.timestamp }

        let replayResult = replay(shiftedPackets)
        let integration = replayResult.integration

        // If this snapshot has no inferred/classic split, skip strict mode-source assertions.
        let hybridNeighbors = integration.currentNeighbors(forMode: .hybrid)
        let hybridRoutes = integration.currentRoutes(forMode: .hybrid)
        guard !hybridNeighbors.isEmpty || !hybridRoutes.isEmpty else {
            throw XCTSkip("Shifted replay produced no routes-page data")
        }

        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "AXTermTests.NetRomSQLite.\(UUID().uuidString)") ?? .standard)
        let viewModel = NetRomRoutesViewModel(
            integration: integration,
            packetEngine: nil,
            settings: settings,
            clock: FixedClock(now: syntheticNow)
        )

        viewModel.setMode(.classic)
        viewModel.refresh()
        XCTAssertTrue(viewModel.routes.allSatisfy { $0.sourceType == "classic" || $0.sourceType == "broadcast" }, "Classic mode should only show classic/broadcast routes")

        viewModel.setMode(.inference)
        viewModel.refresh()
        XCTAssertTrue(viewModel.routes.allSatisfy { $0.sourceType == "inferred" }, "Inference mode should only show inferred routes")

        viewModel.setMode(.hybrid)
        viewModel.refresh()
        let hybridRoutesCount = viewModel.routes.count
        XCTAssertGreaterThanOrEqual(hybridRoutesCount, integration.currentRoutes(forMode: .classic).count, "Hybrid routes should include classic set")
        XCTAssertGreaterThanOrEqual(hybridRoutesCount, integration.currentRoutes(forMode: .inference).count, "Hybrid routes should include inferred set")

        // Ignore propagation contract on real data (neighbors/routes/link stats must all hide ignored endpoint).
        let candidate = (viewModel.neighbors.first?.callsign)
            ?? (viewModel.routes.first?.destination)
            ?? (viewModel.linkStats.first?.fromCall)

        guard let endpointToIgnore = candidate else {
            throw XCTSkip("No endpoint available for ignore-propagation contract")
        }

        settings.addIgnoredServiceEndpoint(endpointToIgnore)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        viewModel.refresh()

        let normalized = CallsignValidator.normalize(endpointToIgnore)
        XCTAssertFalse(viewModel.neighbors.contains { CallsignValidator.normalize($0.callsign) == normalized }, "Ignored endpoint should be removed from neighbors table")
        XCTAssertFalse(viewModel.routes.contains {
            CallsignValidator.normalize($0.destination) == normalized ||
            CallsignValidator.normalize($0.nextHop) == normalized ||
            $0.path.contains(where: { CallsignValidator.normalize($0) == normalized })
        }, "Ignored endpoint should be removed from routes table")
        XCTAssertFalse(viewModel.linkStats.contains {
            CallsignValidator.normalize($0.fromCall) == normalized ||
            CallsignValidator.normalize($0.toCall) == normalized
        }, "Ignored endpoint should be removed from link-stats table")
    }

    // MARK: - Helpers

    private struct ReplayResult {
        let integration: NetRomIntegration
        let neighbors: [NeighborInfo]
        let routes: [RouteInfo]
        let linkStats: [LinkStatRecord]
    }

    private struct FixedClock: ClockProviding {
        let now: Date
    }

    private func replay(_ packets: [Packet]) -> ReplayResult {
        let integration = NetRomIntegration(
            localCallsign: localCallsign,
            mode: .hybrid,
            routerConfig: .default,
            inferenceConfig: .default,
            linkConfig: .default
        )

        for packet in packets {
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        return ReplayResult(
            integration: integration,
            neighbors: integration.currentNeighbors(forMode: .hybrid),
            routes: integration.currentRoutes(forMode: .hybrid),
            linkStats: integration.exportLinkStats(forMode: .hybrid)
        )
    }

    private func loadSQLiteSnapshotPackets() throws -> [Packet] {
        let envPath = ProcessInfo.processInfo.environment["AXTERM_HEALTH_SQLITE_PATH"]
        let defaultSnapshotPath = "/Users/rwardrup/dev/AXTerm/axterm.sqlite"
        let path = (envPath?.isEmpty == false) ? envPath! : defaultSnapshotPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("SQLite snapshot not found at \(path)")
        }

        let dbQueue = try DatabaseQueue(path: path)
        let store = SQLitePacketStore(dbQueue: dbQueue)

        guard let newest = try store.loadRecent(limit: 1).first else {
            return []
        }

        let end = newest.receivedAt.addingTimeInterval(1)
        let start = end.addingTimeInterval(-7 * 24 * 60 * 60)
        let window = DateInterval(start: start, end: end)
        return try store.loadPackets(in: window)
    }

    private func shiftPacketsToReferenceNow(_ packets: [Packet], referenceNow: Date) -> [Packet] {
        guard let newest = packets.map(\.timestamp).max() else { return packets }
        let targetNewest = referenceNow.addingTimeInterval(-15)
        let delta = targetNewest.timeIntervalSince(newest)
        return packets.map { packet in
            Packet(
                id: packet.id,
                timestamp: packet.timestamp.addingTimeInterval(delta),
                from: packet.from,
                to: packet.to,
                via: packet.via,
                frameType: packet.frameType,
                control: packet.control,
                controlByte1: packet.controlByte1,
                pid: packet.pid,
                info: packet.info,
                rawAx25: packet.rawAx25,
                kissEndpoint: packet.kissEndpoint,
                infoText: packet.infoText
            )
        }
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )) ?? Date(timeIntervalSince1970: 0)
    }

    private func fingerprint(of neighbors: [NeighborInfo]) -> String {
        neighbors
            .map { "\(CallsignValidator.normalize($0.call))|\($0.quality)|\($0.sourceType)" }
            .sorted()
            .joined(separator: ";")
    }

    private func fingerprint(of routes: [RouteInfo]) -> String {
        routes
            .map {
                "\(CallsignValidator.normalize($0.destination))|\(CallsignValidator.normalize($0.origin))|\($0.quality)|\($0.sourceType)|\($0.path.map(CallsignValidator.normalize).joined(separator: ">"))"
            }
            .sorted()
            .joined(separator: ";")
    }

    private func fingerprint(of linkStats: [LinkStatRecord]) -> String {
        linkStats
            .map {
                "\(CallsignValidator.normalize($0.fromCall))|\(CallsignValidator.normalize($0.toCall))|\($0.quality)|\($0.observationCount)|\($0.duplicateCount)"
            }
            .sorted()
            .joined(separator: ";")
    }
}
