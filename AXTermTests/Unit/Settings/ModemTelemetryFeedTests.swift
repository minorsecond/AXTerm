//
//  ModemTelemetryFeedTests.swift
//  AXTermTests
//
//  The radio page's live telemetry comes from a feed of its own, watched
//  only by the views that show it, so the form is not redrawn ten times a
//  second. Smoke run 2026-10-03-1, issue 13: each redraw of the whole radio
//  form left SwiftUI observation records behind, about 8 MB a minute.
//

import Combine
import XCTest
@testable import AXTerm

@MainActor
final class ModemTelemetryFeedTests: XCTestCase {

    private func telemetry(peak: Float) -> ModemTelemetry {
        var t = ModemTelemetry()
        t.rxPeakDBFS = peak
        return t
    }

    func testNothingIsReadUntilAViewWatches() {
        let source = CurrentValueSubject<ModemTelemetry?, Never>(telemetry(peak: -10))
        let feed = ModemTelemetryFeed(source: source.eraseToAnyPublisher())
        XCTAssertNil(feed.telemetry)
        feed.startWatching()
        XCTAssertEqual(feed.telemetry?.rxPeakDBFS, -10)
    }

    func testAWatchedFeedFollowsTheSource() {
        let source = CurrentValueSubject<ModemTelemetry?, Never>(nil)
        let feed = ModemTelemetryFeed(source: source.eraseToAnyPublisher())
        feed.startWatching()
        source.send(telemetry(peak: -12))
        XCTAssertEqual(feed.telemetry?.rxPeakDBFS, -12)
    }

    func testTheFeedStopsWhenTheLastViewGoes() {
        let source = CurrentValueSubject<ModemTelemetry?, Never>(nil)
        let feed = ModemTelemetryFeed(source: source.eraseToAnyPublisher())
        feed.startWatching()
        feed.startWatching()
        feed.stopWatching()
        source.send(telemetry(peak: -20))
        XCTAssertEqual(feed.telemetry?.rxPeakDBFS, -20, "one view still watches")
        feed.stopWatching()
        source.send(telemetry(peak: -30))
        XCTAssertEqual(feed.telemetry?.rxPeakDBFS, -20, "nobody watches: no updates")
    }

    func testAnUnchangedReportDoesNotRedraw() {
        let source = CurrentValueSubject<ModemTelemetry?, Never>(nil)
        let feed = ModemTelemetryFeed(source: source.eraseToAnyPublisher())
        feed.startWatching()
        var changes = 0
        let sink = feed.objectWillChange.sink { changes += 1 }
        source.send(telemetry(peak: -15))
        source.send(telemetry(peak: -15))
        XCTAssertEqual(changes, 1)
        sink.cancel()
    }

    func testStoppingMoreThanStartingIsHarmless() {
        let source = CurrentValueSubject<ModemTelemetry?, Never>(nil)
        let feed = ModemTelemetryFeed(source: source.eraseToAnyPublisher())
        feed.stopWatching()
        feed.startWatching()
        source.send(telemetry(peak: -9))
        XCTAssertEqual(feed.telemetry?.rxPeakDBFS, -9)
    }
}
