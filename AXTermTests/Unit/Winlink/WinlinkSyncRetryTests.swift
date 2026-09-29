import XCTest
import CloudKit
@testable import AXTerm

/// The failure that prompted this, and the ones that must still be reported.
final class WinlinkSyncRetryTests: XCTestCase {

    /// The capture: CKError 4 wrapping -1005 on a background task, six
    /// seconds after the app came back to the foreground.
    func testADroppedConnectionIsRetried() {
        let underlying = NSError(domain: NSURLErrorDomain,
                                 code: NSURLErrorNetworkConnectionLost)
        let error = CKError(.networkFailure, userInfo: [NSUnderlyingErrorKey: underlying])
        let plan = WinlinkSyncRetry.plan(for: error, attempt: 1)
        XCTAssertEqual(plan?.delay, 2)
        XCTAssertEqual(plan?.reason, "the connection dropped")
    }

    /// A bare URL error, without CloudKit wrapping it.
    func testABareURLErrorIsRetried() {
        for code in [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                     NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
                     NSURLErrorDNSLookupFailed] {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertNotNil(WinlinkSyncRetry.plan(for: error, attempt: 1), "\(code)")
        }
    }

    /// When iCloud says how long to wait, that number wins — retrying
    /// sooner than asked earns a longer wait next time.
    func testTheServersOwnDelayIsHonoured() {
        let error = CKError(.requestRateLimited,
                            userInfo: [CKErrorRetryAfterKey: 17.0])
        let plan = WinlinkSyncRetry.plan(for: error, attempt: 1)
        XCTAssertEqual(plan?.delay, 17)
        XCTAssertEqual(plan?.reason, "iCloud asked for 17s")
    }

    func testBusyServiceIsRetried() {
        for code: CKError.Code in [.serviceUnavailable, .zoneBusy, .requestRateLimited] {
            let plan = WinlinkSyncRetry.plan(for: CKError(code), attempt: 1)
            XCTAssertEqual(plan?.reason, "iCloud was busy", "\(code)")
        }
    }

    /// An answer from iCloud, not the absence of one. Retrying a refusal is
    /// how an app hammers a service that has already said no.
    func testARealRefusalIsNotRetried() {
        for code: CKError.Code in [.notAuthenticated, .permissionFailure,
                                   .quotaExceeded, .badContainer, .invalidArguments] {
            XCTAssertNil(WinlinkSyncRetry.plan(for: CKError(code), attempt: 1), "\(code)")
        }
    }

    func testAnUnrelatedErrorIsNotRetried() {
        let error = NSError(domain: "AXTerm.Test", code: 1)
        XCTAssertNil(WinlinkSyncRetry.plan(for: error, attempt: 1))
    }

    /// Backoff doubles, and stops. Something that survives three attempts is
    /// an outage worth telling the operator about.
    func testAttemptsAreBoundedAndBackOff() {
        let error = NSError(domain: NSURLErrorDomain,
                            code: NSURLErrorNetworkConnectionLost)
        XCTAssertEqual(WinlinkSyncRetry.plan(for: error, attempt: 1)?.delay, 2)
        XCTAssertEqual(WinlinkSyncRetry.plan(for: error, attempt: 2)?.delay, 4)
        XCTAssertNil(WinlinkSyncRetry.plan(for: error, attempt: 3))
    }

    // MARK: - Foreground debounce

    /// A three-second background is not a reason to sync again, and every
    /// extra pass is another first request on a possibly-stale connection.
    func testAForegroundRightAfterAPassIsSkipped() {
        let now = Date()
        XCTAssertFalse(WinlinkSyncRetry.shouldSyncOnForeground(
            lastCompletedAt: now.addingTimeInterval(-3), now: now))
    }

    func testAForegroundAfterTheDebounceRuns() {
        let now = Date()
        XCTAssertTrue(WinlinkSyncRetry.shouldSyncOnForeground(
            lastCompletedAt: now.addingTimeInterval(-90), now: now))
    }

    /// The first foreground of a launch has nothing to debounce against.
    func testTheFirstForegroundAlwaysSyncs() {
        XCTAssertTrue(WinlinkSyncRetry.shouldSyncOnForeground(
            lastCompletedAt: nil, now: Date()))
    }
}
