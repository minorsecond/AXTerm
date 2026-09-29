import XCTest
@testable import AXTerm

/// Nothing may put a transmitter on the air because a list selection
/// changed.
///
/// Choosing a name from a dropdown is how an operator *looks* at something.
/// Connecting is a decision to transmit — on a shared channel, into a
/// station that may be mid-net — and it has exactly one trigger: the
/// Connect button. Selection and transmission being one gesture is the kind
/// of surprise that costs somebody else their QSO.
///
/// The rule lives on `ConnectRequest` rather than in each view because
/// there are already a dozen places that build one, and a thirteenth is
/// always about to be written.
final class ConnectOriginTests: XCTestCase {

    private func intent(_ to: String = "DRLNOD") -> ConnectIntent {
        ConnectIntent(
            kind: .ax25Direct,
            to: to,
            sourceContext: .terminal,
            suggestedRoutePreview: nil,
            validationErrors: [],
            routeHint: nil,
            note: nil)
    }

    /// The headline invariant. A selection may fill the bar in; it may not
    /// press the button.
    func testASelectionCanNeverExecuteImmediately() {
        let request = ConnectRequest(
            intent: intent(), mode: .ax25,
            executeImmediately: true, origin: .selection)

        XCTAssertFalse(request.executeImmediately,
                       "selecting a node started a connection")
    }

    /// …and it still prefills, because that is the useful half.
    func testASelectionStillPrefillsTheBar() {
        let request = ConnectRequest(
            intent: intent("KB5YZB-7"), mode: .netrom,
            executeImmediately: true, origin: .selection)

        XCTAssertEqual(request.intent.to, "KB5YZB-7")
        XCTAssertEqual(request.mode, .netrom)
    }

    /// An explicit action — the Connect button, a "Connect" menu item — is
    /// exactly what may transmit.
    func testAnExplicitActionMayExecuteImmediately() {
        let request = ConnectRequest(
            intent: intent(), mode: .ax25,
            executeImmediately: true, origin: .explicitAction)

        XCTAssertTrue(request.executeImmediately)
    }

    func testAnExplicitActionMayAlsoOnlyPrefill() {
        let request = ConnectRequest(
            intent: intent(), mode: .ax25,
            executeImmediately: false, origin: .explicitAction)

        XCTAssertFalse(request.executeImmediately)
    }

    /// The default is the safe one. A call site that says nothing about
    /// where it came from must not be granted the right to transmit.
    func testTheDefaultOriginIsASelection() {
        let request = ConnectRequest(
            intent: intent(), mode: .ax25, executeImmediately: true)

        XCTAssertEqual(request.origin, .selection)
        XCTAssertFalse(request.executeImmediately)
    }

    /// Navigation follows execution, so a selection must not yank the
    /// operator to the terminal either.
    func testASelectionDoesNotNavigate() {
        let request = ConnectRequest(
            intent: intent(), mode: .ax25,
            executeImmediately: true, origin: .selection)

        XCTAssertFalse(ConnectPrefillLogic.shouldNavigateOnConnect(request))
    }
}
