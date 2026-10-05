//
//  ChannelFigureDuringSessionTests.swift
//  AXTermTests
//
//  The toolbar's channel figure must follow what the channel learns from a
//  session's samples. Smoke run 2026-10-03-1, issue 51: B (ID-50)'s route
//  had collapsed to K 1 / P 64 while the toolbar still showed the channel at
//  K 4 / P 256, the figure from the network sample taken before the session.
//

import XCTest
@testable import AXTerm

@MainActor
final class ChannelFigureDuringSessionTests: XCTestCase {

    override func tearDown() {
        SessionCoordinator.shared = nil
        super.tearDown()
    }

    func testRouteSamplesRefreshTheChannelFigure() {
        let coordinator = SessionCoordinator()
        coordinator.adaptiveTransmissionEnabled = true
        let channel = coordinator.adaptiveSessionID(radio: .primary, destination: "", path: "")

        // Before the session: a clean network sample files the channel.
        for _ in 0..<40 {
            coordinator.applyLinkQualitySample(lossRate: 0, etx: 1.0, srtt: nil,
                                               source: "network", scope: .radio(.primary),
                                               evidence: .observed)
        }
        let before = coordinator.adaptiveStatusStore.sessionAdaptiveByID[channel]
        XCTAssertNotNil(before)

        // The session: one frame in three resent, on a route over this radio.
        let route = AdaptiveScope.route(radio: .primary, destination: "K0EPI-2", path: "")
        for _ in 0..<30 {
            coordinator.applyLinkQualitySample(lossRate: 0.34, forwardLoss: 0.34, etx: 2.3, srtt: 3.0,
                                               source: "session", scope: route,
                                               newFrames: 3, retransmits: 1)
        }
        let shown = coordinator.adaptiveStatusStore.sessionAdaptiveByID[channel]
        let channelSettings = coordinator.channelSettingsForTesting(.primary)
        XCTAssertEqual(shown?.k, channelSettings?.windowSize.effectiveValue,
                       "the toolbar shows the channel's K as it is now, not as the network sample left it")
        XCTAssertEqual(shown?.p, channelSettings?.paclen.effectiveValue)
        XCTAssertLessThan(shown?.k ?? 99, before?.k ?? 0, "the losses moved the channel")
    }

    func testARouteSampleOnANewRadioMakesItsChannelTheDefault() {
        let coordinator = SessionCoordinator()
        coordinator.adaptiveTransmissionEnabled = true
        let route = AdaptiveScope.route(radio: .primary, destination: "K0EPI-2", path: "")
        coordinator.applyLinkQualitySample(lossRate: 0, etx: 1.0, srtt: 3.0,
                                           source: "session", scope: route,
                                           newFrames: 1, retransmits: 0)
        XCTAssertEqual(coordinator.adaptiveStatusStore.defaultChannelID,
                       coordinator.adaptiveSessionID(radio: .primary, destination: "", path: ""),
                       "a station whose only evidence is its sessions still has a channel to show")
    }
}
