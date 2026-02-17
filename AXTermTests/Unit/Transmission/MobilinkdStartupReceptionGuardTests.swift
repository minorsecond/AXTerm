import XCTest
@testable import AXTerm

final class MobilinkdStartupReceptionGuardTests: XCTestCase {

    func testShouldIssueResetWhenNoAX25Seen() {
        let guardState = MobilinkdStartupReceptionGuard()
        guardState.resetForNewConnection()

        XCTAssertTrue(
            guardState.shouldIssueRecoveryReset(isConnected: true, isMobilinkd: true),
            "Startup recovery reset should fire when no inbound AX.25 was observed."
        )
    }

    func testDoesNotIssueResetWhenAX25Observed() {
        let guardState = MobilinkdStartupReceptionGuard()
        guardState.resetForNewConnection()

        let ax25Frame = Data([0x96, 0x88, 0x8A, 0xA6, 0x40, 0x40, 0xE0, 0x96, 0x88, 0x8A, 0xA6, 0x40, 0x40, 0x61, 0x03, 0xF0])
        let kiss = KISS.encodeFrame(payload: ax25Frame, port: 0)
        guardState.observeInboundChunk(kiss)

        XCTAssertFalse(
            guardState.shouldIssueRecoveryReset(isConnected: true, isMobilinkd: true),
            "Any inbound AX.25 during startup must suppress the recovery reset."
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
            guardState.shouldIssueRecoveryReset(isConnected: true, isMobilinkd: true),
            "If valid inbound KISS traffic exists, startup demod reset should be suppressed."
        )
    }

    func testResetIsOneShot() {
        let guardState = MobilinkdStartupReceptionGuard()
        guardState.resetForNewConnection()

        XCTAssertTrue(guardState.shouldIssueRecoveryReset(isConnected: true, isMobilinkd: true))
        XCTAssertFalse(
            guardState.shouldIssueRecoveryReset(isConnected: true, isMobilinkd: true),
            "Recovery reset must be one-shot per connection."
        )
    }

    func testDoesNotIssueResetWhenDisconnectedOrNonMobilinkd() {
        let guardState = MobilinkdStartupReceptionGuard()
        guardState.resetForNewConnection()

        XCTAssertFalse(guardState.shouldIssueRecoveryReset(isConnected: false, isMobilinkd: true))
        XCTAssertFalse(guardState.shouldIssueRecoveryReset(isConnected: true, isMobilinkd: false))
    }
}
