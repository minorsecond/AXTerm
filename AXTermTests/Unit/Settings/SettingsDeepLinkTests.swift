//
//  SettingsDeepLinkTests.swift
//  AXTermTests
//
//  Every way into Settings from outside lands on the page and section that
//  holds the setting, and a pushed stack (iOS) is added to rather than
//  thrown away.
//
//  Exercised on the shared router, restoring what each test changes; see
//  SettingsRouterRadioTests for why.
//

import XCTest
@testable import AXTerm

@MainActor
final class SettingsDeepLinkTests: XCTestCase {

    private var savedTab: SettingsTab = .general
    private var savedAction: (() -> Void)?

    override func setUp() {
        super.setUp()
        let router = SettingsRouter.shared
        savedTab = router.selectedTab
        savedAction = router.openAction
        router.openAction = nil
        router.pendingRadio = nil
        router.highlightSection = nil
        router.showsSetup = false
    }

    override func tearDown() {
        let router = SettingsRouter.shared
        router.pendingRadio = nil
        router.highlightSection = nil
        router.showsSetup = false
        router.selectedTab = savedTab
        router.openAction = savedAction
        super.tearDown()
    }

    func testASectionLinkOpensItsPageAndLeavesTheSectionPending() {
        let router = SettingsRouter.shared
        var opened = 0
        router.openAction = { opened += 1 }
        router.navigate(to: .stationPosition)
        XCTAssertEqual(router.selectedTab, .general)
        XCTAssertEqual(router.highlightSection, .stationPosition)
        XCTAssertEqual(opened, 1, "the shell is asked to show Settings")
    }

    func testARadioSectionLinkNamesTheRadioToo() {
        let router = SettingsRouter.shared
        let id = RadioID(rawValue: "ic705")
        router.navigate(to: .radioTiming, radio: id)
        XCTAssertEqual(router.selectedTab, .radios)
        XCTAssertEqual(router.pendingRadio, id)
        XCTAssertEqual(router.highlightSection, .radioTiming)
    }

    func testASectionOnAnotherPageIsIgnored() {
        let router = SettingsRouter.shared
        router.navigate(to: .aprs, section: .ping)
        XCTAssertEqual(router.selectedTab, .aprs)
        XCTAssertNil(router.highlightSection, "Ping is on Packet Node, not APRS")
    }

    func testThePageThatHoldsTheSectionTakesItOnce() {
        let router = SettingsRouter.shared
        router.navigate(to: .linkLayer)
        XCTAssertNil(router.consume([.stationIdentity]), "another page leaves it alone")
        XCTAssertEqual(router.highlightSection, .linkLayer)
        XCTAssertEqual(router.consume([.linkLayer, .ping]), .linkLayer)
        XCTAssertNil(router.highlightSection, "taken, so the next visit does not jump")
        XCTAssertNil(router.consume([.linkLayer]))
    }

    /// Where each outside link goes, as the call sites name it.
    func testTheOutsideLinksLandWhereTheSettingIs() {
        XCTAssertEqual(SettingsSection.stationPosition.tab, .general, "the position chip")
        XCTAssertEqual(SettingsSection.radioConnection.tab, .radios, "TNC Settings, Radio Settings")
        XCTAssertEqual(SettingsSection.radioChannel.tab, .radios, "the packet services' APRS note")
        XCTAssertEqual(SettingsSection.netRomNode.tab, .packetNode)
    }

    func testTheCallsignBannerOpensSetup() {
        let router = SettingsRouter.shared
        router.presentSetup()
        XCTAssertTrue(router.showsSetup)
    }

    // MARK: - A pushed stack

    func testLandingOnThePageAlreadyShowingChangesNothing() {
        XCTAssertEqual(SettingsDeepLink.path(current: ["radios", "base"], target: ["radios", "base"],
                                             stackIsShowing: true),
                       ["radios", "base"])
    }

    func testALinkFromAnotherPageInTheStackIsPushed() {
        XCTAssertEqual(SettingsDeepLink.path(current: ["winlink"], target: ["radios", "base"],
                                             stackIsShowing: true),
                       ["winlink", "radios", "base"], "Back returns to Winlink")
    }

    func testALinkToAPageAlreadyInTheStackGoesBackToIt() {
        XCTAssertEqual(SettingsDeepLink.path(current: ["radios", "base", "extra"],
                                             target: ["radios", "uhf"], stackIsShowing: true),
                       ["radios", "uhf"])
    }

    func testAStackBehindAnotherTabIsReplaced() {
        XCTAssertEqual(SettingsDeepLink.path(current: ["winlink", "mailbox"], target: ["general"],
                                             stackIsShowing: false),
                       ["general"])
    }
}
