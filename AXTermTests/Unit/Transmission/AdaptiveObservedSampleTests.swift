//
//  AdaptiveObservedSampleTests.swift
//  AXTermTests
//
//  Only evidence about our own frames moves K and paclen.
//
//  Smoke run 2026-10-03-1, issue 5: before A (705) had sent a frame, the
//  network poll filed other stations' links on 145.070 against its channel,
//  the channel read "Our frames losing 23%", and the first session to
//  K0EPI-3 opened at K=1 paclen 64. The poll re-files the same stored link
//  statistics every cycle, and they describe other stations' links, so
//  neither our spec's success rule (our I-frame acked without a retransmit)
//  nor its failure rule applies. Observed samples still feed the loss and
//  ETX figures the operator sees; they no longer resize anything.
//

import XCTest
@testable import AXTerm

final class AdaptiveObservedSampleTests: XCTestCase {

    func testObservedLossDoesNotMoveKOrPaclen() {
        var settings = TxAdaptiveSettings()
        let window = settings.windowSize.currentAdaptive
        let paclen = settings.paclen.currentAdaptive

        for _ in 0..<10 {
            settings.updateFromLinkQuality(lossRate: 0.4, etx: 3.0, srtt: nil, evidence: .observed)
        }

        XCTAssertEqual(settings.windowSize.currentAdaptive, window)
        XCTAssertEqual(settings.paclen.currentAdaptive, paclen)
        XCTAssertEqual(settings.lossRateEWMA ?? 0, 0.4, accuracy: 0.05, "the figure the operator sees still learns")
        XCTAssertNotNil(settings.etxEWMA)
    }

    /// Observed loss must not wait in the forward average for our first own
    /// sample to trip over.
    func testObservedLossDoesNotColorOurOwnFirstSample() {
        var settings = TxAdaptiveSettings()
        let window = settings.windowSize.currentAdaptive
        let paclen = settings.paclen.currentAdaptive
        for _ in 0..<10 {
            settings.updateFromLinkQuality(lossRate: 0.4, etx: 3.0, srtt: nil, evidence: .observed)
        }

        settings.updateFromLinkQuality(lossRate: 0.0, forwardLoss: 0.0, etx: 1.0, srtt: 2.0,
                                       newFrames: 1, retransmits: 0)

        XCTAssertEqual(settings.windowSize.currentAdaptive, window)
        XCTAssertEqual(settings.paclen.currentAdaptive, paclen)
        XCTAssertFalse(settings.paclen.adaptiveReason?.contains("Our frames") ?? false,
                       settings.paclen.adaptiveReason ?? "nil")
    }

    /// Our own losses still back off at once.
    func testOwnLossStillBacksOff() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.3, forwardLoss: 0.3, etx: 2.5, srtt: 2.0,
                                       newFrames: 1, retransmits: 1)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 1)
        XCTAssertEqual(settings.paclen.currentAdaptive, 64)
    }

    /// The field case end to end: a channel-wide poll result, then the first
    /// session to a station nobody has connected to yet.
    @MainActor
    func testANewRouteOpensAtTheBaselineAfterChannelWideLoss() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.adaptiveTransmissionEnabled = true
        let before = coordinator.sessionManager.getConfigForDestination?("K0EPI-3", "", .primary)

        for _ in 0..<5 {
            coordinator.applyLinkQualitySample(lossRate: 0.23, etx: 2.0, srtt: nil,
                                               source: AdaptiveAggregateScope.channelWide.sourceLabel,
                                               scope: .radio(.primary), evidence: .observed)
        }

        let after = coordinator.sessionManager.getConfigForDestination?("K0EPI-3", "", .primary)
        XCTAssertEqual(after?.windowSize, before?.windowSize)
        XCTAssertEqual(after?.paclen, before?.paclen)
    }
}
