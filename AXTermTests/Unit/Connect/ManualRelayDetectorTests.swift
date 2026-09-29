import XCTest
@testable import AXTerm

final class ManualRelayDetectorTests: XCTestCase {

    // MARK: - Outgoing command parsing

    func testConnectCommandUppercase() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        guard case .pending(let dest) = d.state else {
            return XCTFail("Expected .pending, got \(d.state)")
        }
        XCTAssertEqual(dest, "KB5YZB-7")
    }

    func testConnectCommandLowercase() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("c kb5yzb-7")
        guard case .pending(let dest) = d.state else {
            return XCTFail("Expected .pending, got \(d.state)")
        }
        XCTAssertEqual(dest, "KB5YZB-7")
    }

    func testConnectCommandExtraInternalSpaces() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C  KB5YZB-7")
        guard case .pending(let dest) = d.state else {
            return XCTFail("Expected .pending for extra spaces, got \(d.state)")
        }
        XCTAssertEqual(dest, "KB5YZB-7")
    }

    func testConnectCommandLeadingTrailingWhitespace() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("  C N0CALL  ")
        guard case .pending(let dest) = d.state else {
            return XCTFail("Expected .pending after trimming, got \(d.state)")
        }
        XCTAssertEqual(dest, "N0CALL")
    }

    func testConnectCommandWithSSID() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C N0CALL-15")
        guard case .pending(let dest) = d.state else {
            return XCTFail("Expected .pending with SSID, got \(d.state)")
        }
        XCTAssertEqual(dest, "N0CALL-15")
    }

    func testConnectCommandTacticalAlias() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C DRLBBS")
        guard case .pending(let dest) = d.state else {
            return XCTFail("Expected .pending for tactical alias, got \(d.state)")
        }
        XCTAssertEqual(dest, "DRLBBS")
    }

    func testNonConnectCommandsIgnored() {
        for command in ["B", "J", "N", "H", "HELP", "Hello world", "D"] {
            var d = ManualRelayDetector()
            _ = d.processOutgoing(command)
            XCTAssertEqual(d.state, .idle, "'\(command)' should not transition from idle")
        }
    }

    func testConnectCommandMissingCallsignIgnored() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C ")
        XCTAssertEqual(d.state, .idle)
    }

    func testConnectCommandInvalidSSIDIgnored() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C N0CALL-99")
        XCTAssertEqual(d.state, .idle, "SSID 99 is out of range and should not create pending state")
    }

    func testConnectCommandNoSpaceIgnored() {
        var d = ManualRelayDetector()
        // "CONNECT" starts with C but has no space separator
        _ = d.processOutgoing("CONNECT")
        XCTAssertEqual(d.state, .idle)
    }

    // MARK: - Incoming response parsing

    func testLinkMadeEstablishesRelay() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        _ = d.processIncoming("###LINK MADE.")
        guard case .established(let dest) = d.state else {
            return XCTFail("Expected .established, got \(d.state)")
        }
        XCTAssertEqual(dest, "KB5YZB-7")
    }

    func testLinkMadeCaseInsensitive() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        _ = d.processIncoming("###link made.")
        guard case .established = d.state else {
            return XCTFail("Expected .established for lowercase ###link made, got \(d.state)")
        }
    }

    func testLinkMadeWithoutPendingIsNoop() {
        var d = ManualRelayDetector()
        _ = d.processIncoming("###LINK MADE.")
        XCTAssertEqual(d.state, .idle, "###LINK MADE. without pending command should stay idle")
    }

    func testLinkFailedClearsPending() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        _ = d.processIncoming("###LINK FAILED with KB5YZB-7")
        XCTAssertEqual(d.state, .idle)
    }

    func testLinkFailedWithoutPendingIsNoop() {
        var d = ManualRelayDetector()
        _ = d.processIncoming("###LINK FAILED with KB5YZB-7")
        XCTAssertEqual(d.state, .idle)
    }

    func testNetRomPromptClearsEstablished() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        _ = d.processIncoming("###LINK MADE.")
        _ = d.processIncoming("ENTER COMMAND: B,C,J,N, or Help ?")
        XCTAssertEqual(d.state, .idle)
    }

    func testEnterCmdVariantClearsEstablished() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        _ = d.processIncoming("###LINK MADE.")
        _ = d.processIncoming("ENTER CMD:")
        XCTAssertEqual(d.state, .idle)
    }

    func testDisconnectedFromClearsEstablished() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        _ = d.processIncoming("###LINK MADE.")
        _ = d.processIncoming("###DISCONNECTED FROM KB5YZB-7")
        XCTAssertEqual(d.state, .idle)
    }

    func testDisconnectedFromClearsPending() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        _ = d.processIncoming("###DISCONNECTED FROM KB5YZB-7")
        XCTAssertEqual(d.state, .idle)
    }

    func testNetRomPromptWhenIdleIsNoop() {
        var d = ManualRelayDetector()
        _ = d.processIncoming("ENTER COMMAND: B,C,J,N, or Help ?")
        XCTAssertEqual(d.state, .idle)
    }

    func testNetRomPromptWhenPendingClearsPending() {
        // If we sent C but receive the prompt again (node rejected without ###LINK FAILED),
        // we should go back to idle
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        _ = d.processIncoming("ENTER COMMAND: B,C,J,N, or Help ?")
        XCTAssertEqual(d.state, .idle)
    }

    // MARK: - Chained relays

    func testChainedRelayOverridesEstablished() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        _ = d.processIncoming("###LINK MADE.")
        // User now sends another C command to relay further
        _ = d.processOutgoing("C N0HI-7")
        _ = d.processIncoming("###LINK MADE.")
        guard case .established(let dest) = d.state else {
            return XCTFail("Expected .established with second destination, got \(d.state)")
        }
        XCTAssertEqual(dest, "N0HI-7")
    }

    func testChainedRelayFailFallsBackToFirstRelay() {
        // Re-relay attempt fails — the original relay was already established.
        // The detector returns to idle (the actual net/rom state is ambiguous,
        // so we conservatively clear rather than preserving the first relay).
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        _ = d.processIncoming("###LINK MADE.")
        _ = d.processOutgoing("C N0HI-7")
        _ = d.processIncoming("###LINK FAILED with N0HI-7")
        XCTAssertEqual(d.state, .idle)
    }

    // MARK: - clear()

    func testClearResetsFromPending() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        d.clear()
        XCTAssertEqual(d.state, .idle)
    }

    func testClearResetsFromEstablished() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        _ = d.processIncoming("###LINK MADE.")
        d.clear()
        XCTAssertEqual(d.state, .idle)
    }

    // MARK: - Convenience accessor

    func testActiveRelayDestinationNilWhenIdle() {
        let d = ManualRelayDetector()
        XCTAssertNil(d.activeRelayDestination)
    }

    func testActiveRelayDestinationNilWhenPending() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        XCTAssertNil(d.activeRelayDestination, "Pending state should not expose a destination yet")
    }

    func testActiveRelayDestinationSetWhenEstablished() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        _ = d.processIncoming("###LINK MADE.")
        XCTAssertEqual(d.activeRelayDestination, "KB5YZB-7")
    }

    func testActiveRelayDestinationClearedAfterDisconnect() {
        var d = ManualRelayDetector()
        _ = d.processOutgoing("C KB5YZB-7")
        _ = d.processIncoming("###LINK MADE.")
        d.clear()
        XCTAssertNil(d.activeRelayDestination)
    }

    // MARK: - parseConnectCommand static helper

    func testParseConnectCommandValidCases() {
        let cases: [(String, String)] = [
            ("C N0CALL", "N0CALL"),
            ("c n0call", "N0CALL"),
            ("C N0CALL-7", "N0CALL-7"),
            ("C N0CALL-15", "N0CALL-15"),
            ("C DRLNOD", "DRLNOD"),
            ("C DRL", "DRL"),
            ("C  KB5YZB-7", "KB5YZB-7"),
        ]
        for (input, expected) in cases {
            let result = ManualRelayDetector.parseConnectCommand(input.trimmingCharacters(in: .whitespaces))
            XCTAssertEqual(result, expected, "parseConnectCommand('\(input)') should return '\(expected)'")
        }
    }

    func testParseConnectCommandInvalidCases() {
        let invalid = ["CONNECT", "C", "C ", "C N0CALL-99", "C -7", "B N0CALL", "C N0CALL-0X"]
        for input in invalid {
            let result = ManualRelayDetector.parseConnectCommand(input.trimmingCharacters(in: .whitespaces))
            XCTAssertNil(result, "parseConnectCommand('\(input)') should return nil")
        }
    }
}
