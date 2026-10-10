#if os(macOS)
import XCTest
@testable import AXTerm

/// The Connection menu. Its one item took its action from the focused
/// window, so with AXTerm in the background it did nothing and stayed
/// enabled (2026-10-10). It now acts on the engine directly, names what it
/// will do, and lists each radio when there are several, as the menu bar
/// icon does.
final class ConnectionMenuTests: XCTestCase {
    private let a = RadioID(rawValue: "a")
    private let b = RadioID(rawValue: "b")

    func testOneRadioIsOneItem() {
        XCTAssertEqual(ConnectionMenu.items([(a, "IC-705", .connected)]),
                       [.init(title: "Disconnect", target: .all)])
        XCTAssertEqual(ConnectionMenu.items([(a, "IC-705", .failed)]),
                       [.init(title: "Connect", target: .all)])
    }

    func testSeveralRadiosGetOneEachBelowTheAllItem() {
        XCTAssertEqual(ConnectionMenu.items([(a, "IC-705", .connected), (b, "TNC4", .disconnected)]), [
            .init(title: "Disconnect All", target: .all),
            .init(title: "Disconnect IC-705", target: .radio(a)),
            .init(title: "Connect TNC4", target: .radio(b)),
        ])
    }

    func testNoRadiosStillOffersConnect() {
        XCTAssertEqual(ConnectionMenu.items([]), [.init(title: "Connect", target: .all)])
    }
}
#endif
