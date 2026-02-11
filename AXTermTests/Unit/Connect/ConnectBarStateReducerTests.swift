import XCTest
@testable import AXTerm

final class ConnectBarStateReducerTests: XCTestCase {
    func testConnectLifecycleTransitions() {
        let draft = ConnectDraft(
            sourceContext: .terminal,
            destination: "N0HI-7",
            transport: .ax25(.direct)
        )

        var state: ConnectBarState = .disconnectedDraft(draft)
        state = ConnectBarStateReducer.reduce(state: state, event: .connectRequested(draft))
        XCTAssertEqual(state, .connecting(draft))

        let session = SessionInfo(
            sourceContext: .terminal,
            sourceCall: "K0EPI-7",
            destination: "N0HI-7",
            transport: .ax25(via: ["W0ARP-7"]),
            connectedAt: Date(timeIntervalSince1970: 0)
        )

        state = ConnectBarStateReducer.reduce(state: state, event: .connectSucceeded(session))
        XCTAssertEqual(state, .connectedSession(session))

        state = ConnectBarStateReducer.reduce(state: state, event: .disconnectRequested)
        XCTAssertEqual(state, .disconnecting(session))

        let postDisconnectDraft = ConnectDraft(
            sourceContext: .terminal,
            destination: "N0HI-7",
            transport: .ax25(.viaDigipeaters(["W0ARP-7"]))
        )
        state = ConnectBarStateReducer.reduce(state: state, event: .disconnectCompleted(nextDraft: postDisconnectDraft))
        XCTAssertEqual(state, .disconnectedDraft(postDisconnectDraft))
    }

    func testBroadcastModeTransitions() {
        var state: ConnectBarState = .disconnectedDraft(.empty())
        state = ConnectBarStateReducer.reduce(state: state, event: .switchedToBroadcast)

        guard case .broadcastComposer(let composer) = state else {
            XCTFail("Expected broadcast composer state")
            return
        }
        XCTAssertTrue(composer.remembersLastUsedPath)

        state = ConnectBarStateReducer.reduce(state: state, event: .switchedToConnect)
        guard case .disconnectedDraft = state else {
            XCTFail("Expected disconnected draft after switching back to connect")
            return
        }
    }

    func testSidebarSmartDefaultPrefersNetRomWhenRouteExists() {
        let selection = SidebarStationSelection(
            callsign: "N0HI-7",
            context: .stations,
            lastUsedMode: nil,
            hasNetRomRoute: true
        )

        let state = ConnectBarStateReducer.reduce(
            state: .disconnectedDraft(.empty(context: .stations)),
            event: .sidebarSelection(selection, .prefill)
        )

        guard case .disconnectedDraft(let draft) = state else {
            XCTFail("Expected disconnected draft")
            return
        }

        if case .netrom = draft.transport {
            XCTAssertEqual(draft.normalizedDestination, "N0HI-7")
        } else {
            XCTFail("Expected NET/ROM draft transport")
        }
    }

    func testSidebarUsesRememberedModeFirst() {
        let selection = SidebarStationSelection(
            callsign: "N0HI-7",
            context: .stations,
            lastUsedMode: .ax25,
            hasNetRomRoute: true
        )

        let state = ConnectBarStateReducer.reduce(
            state: .disconnectedDraft(.empty(context: .stations)),
            event: .sidebarSelection(selection, .prefill)
        )

        guard case .disconnectedDraft(let draft) = state else {
            XCTFail("Expected disconnected draft")
            return
        }

        if case .ax25 = draft.transport {
            XCTAssertEqual(draft.normalizedDestination, "N0HI-7")
        } else {
            XCTFail("Expected AX.25 draft transport from remembered mode")
        }
    }
}
