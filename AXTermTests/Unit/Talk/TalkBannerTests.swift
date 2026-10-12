//
//  TalkBannerTests.swift
//  AXTermTests
//
//  What the operator is shown when a caller asks to talk: a banner that
//  stays until answered, on every page of the app, and on the Mac a
//  notification with Answer and Not Now.
//

import UserNotifications
import XCTest
@testable import AXTerm

final class TalkBannerTests: XCTestCase {

    func testAPageNamesTheCallerAndTheDoor() {
        XCTAssertEqual(TalkBannerText.page(caller: "K0EPI-3", door: .node), "K0EPI-3 wants to talk (at the node)")
        XCTAssertEqual(TalkBannerText.page(caller: "K0EPI-3", door: .mailbox), "K0EPI-3 wants to talk (at the mailbox)")
    }

    func testAChatSaysHowItEnds() {
        XCTAssertEqual(TalkBannerText.chat(caller: "K0EPI-3"), "Talking with K0EPI-3. They type /EX to go back.")
    }

    func testTheNotificationCarriesThePage() {
        let id = UUID()
        let content = TalkPageNotification.content(caller: "K0EPI-3", door: .node, pageID: id)
        XCTAssertEqual(content.title, "K0EPI-3 wants to talk")
        XCTAssertEqual(content.body, "At the node. Nobody answering in a minute tells them you're away.")
        XCTAssertEqual(content.categoryIdentifier, TalkPageNotification.category)
        XCTAssertEqual(content.userInfo[TalkPageNotification.pageKey] as? String, id.uuidString)
    }
}
