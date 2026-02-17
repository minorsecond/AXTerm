import XCTest
@testable import AXTerm

final class MobilinkdStartupReceptionGuardTests: XCTestCase {

    func testShouldIssueNoInboundKISSResetWhenNoTrafficSeen() {
        let guardState = MobilinkdStartupReceptionGuard()
        guardState.resetForNewConnection()

        XCTAssertTrue(
            guardState.shouldIssueRecoveryReset(
                isConnected: true,
                isMobilinkd: true,
                trigger: .noInboundKISS
            ),
            "Startup no-KISS recovery reset should fire when no inbound traffic was observed."
        )
    }

    func testShouldIssueNoAX25ResetWhenNoAX25Seen() {
        let guardState = MobilinkdStartupReceptionGuard()
        guardState.resetForNewConnection()

        XCTAssertTrue(
            guardState.shouldIssueRecoveryReset(
                isConnected: true,
                isMobilinkd: true,
                trigger: .noInboundAX25
            ),
            "Fallback no-AX.25 recovery reset should fire when no AX.25 was observed."
        )
    }

    func testDoesNotIssueResetWhenAX25Observed() {
        let guardState = MobilinkdStartupReceptionGuard()
        guardState.resetForNewConnection()

        let ax25Frame = Data([0x96, 0x88, 0x8A, 0xA6, 0x40, 0x40, 0xE0, 0x96, 0x88, 0x8A, 0xA6, 0x40, 0x40, 0x61, 0x03, 0xF0])
        let kiss = KISS.encodeFrame(payload: ax25Frame, port: 0)
        guardState.observeInboundChunk(kiss)

        XCTAssertFalse(
            guardState.shouldIssueRecoveryReset(
                isConnected: true,
                isMobilinkd: true,
                trigger: .noInboundKISS
            ),
            "Any inbound AX.25 during startup must suppress no-KISS recovery."
        )
        XCTAssertFalse(
            guardState.shouldIssueRecoveryReset(
                isConnected: true,
                isMobilinkd: true,
                trigger: .noInboundAX25
            ),
            "Any inbound AX.25 during startup must suppress no-AX.25 recovery."
        )
    }

    func testTelemetrySuppressesResetButDoesNotCountAsAX25() {
        let guardState = MobilinkdStartupReceptionGuard()
        guardState.resetForNewConnection()

        // Mobilinkd hardware telemetry response: FEND 0x06 0x06 hi lo FEND
        let telemetry = Data([0xC0, 0x06, 0x06, 0x10, 0x71, 0xC0])
        guardState.observeInboundChunk(telemetry)

        XCTAssertFalse(guardState.hasSeenInboundAX25, "Telemetry must not be treated as AX.25 payload.")
        XCTAssertTrue(guardState.hasSeenInboundKISSFrame, "Telemetry confirms inbound KISS path is alive.")
        XCTAssertFalse(
            guardState.shouldIssueRecoveryReset(
                isConnected: true,
                isMobilinkd: true,
                trigger: .noInboundKISS
            ),
            "If valid inbound KISS traffic exists, no-KISS startup reset should be suppressed."
        )
        XCTAssertTrue(
            guardState.shouldIssueRecoveryReset(
                isConnected: true,
                isMobilinkd: true,
                trigger: .noInboundAX25
            ),
            "If telemetry is present but AX.25 is absent, no-AX.25 recovery should still be allowed."
        )
    }

    func testAX25AfterTelemetryIsStillDetected() {
        let guardState = MobilinkdStartupReceptionGuard()
        guardState.resetForNewConnection()

        let telemetry = Data([0xC0, 0x06, 0x06, 0x10, 0x71, 0xC0])
        guardState.observeInboundChunk(telemetry)
        XCTAssertTrue(guardState.hasSeenInboundKISSFrame)
        XCTAssertFalse(guardState.hasSeenInboundAX25)

        let ax25Frame = Data([0x96, 0x88, 0x8A, 0xA6, 0x40, 0x40, 0xE0, 0x96, 0x88, 0x8A, 0xA6, 0x40, 0x40, 0x61, 0x03, 0xF0])
        let kiss = KISS.encodeFrame(payload: ax25Frame, port: 0)
        guardState.observeInboundChunk(kiss)

        XCTAssertTrue(guardState.hasSeenInboundAX25, "Guard should still parse later AX.25 after telemetry.")
    }

    func testResetIsOneShot() {
        let guardState = MobilinkdStartupReceptionGuard()
        guardState.resetForNewConnection()

        XCTAssertTrue(
            guardState.shouldIssueRecoveryReset(
                isConnected: true,
                isMobilinkd: true,
                trigger: .noInboundKISS
            )
        )
        XCTAssertFalse(
            guardState.shouldIssueRecoveryReset(
                isConnected: true,
                isMobilinkd: true,
                trigger: .noInboundAX25
            ),
            "Recovery reset must be one-shot per connection."
        )
    }

    func testDoesNotIssueResetWhenDisconnectedOrNonMobilinkd() {
        let guardState = MobilinkdStartupReceptionGuard()
        guardState.resetForNewConnection()

        XCTAssertFalse(
            guardState.shouldIssueRecoveryReset(
                isConnected: false,
                isMobilinkd: true,
                trigger: .noInboundKISS
            )
        )
        XCTAssertFalse(
            guardState.shouldIssueRecoveryReset(
                isConnected: true,
                isMobilinkd: false,
                trigger: .noInboundAX25
            )
        )
    }
}
