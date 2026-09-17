import XCTest
@testable import AXTerm

/// What a test run is allowed to reach.
///
/// A test host is injected into the app bundle and carries the app's
/// identifier, so macOS judges a connection it opens as the app's own. On
/// 2026-09-17 a full suite run asked for local network access and the
/// operator's *running* copy lost all three of its UDP streams to the radio
/// one second later, mid-session, while they were on the air. The suite had
/// no business opening that socket in the first place.
final class TestHostNetworkGuardTests: XCTestCase {

    /// This suite is itself the proof: if the guard were not in force here,
    /// these tests could reach the operator's network.
    func testThisIsRunningAsATestHost() {
        XCTAssertTrue(AppEnvironment.isUnitTestHost)
    }

    func testATestHostMayReachLoopbackAndNothingElse() {
        for host in ["localhost", "127.0.0.1", "127.0.0.53", "::1", "[::1]", "db.localhost"] {
            XCTAssertTrue(AppEnvironment.mayConnect(to: host), host)
        }
        for host in ["192.168.3.34", "192.168.3.218", "10.0.0.1", "100.77.243.13",
                     "ham-pi.tail231eb.ts.net", "cms.winlink.org", "example.com"] {
            XCTAssertFalse(AppEnvironment.mayConnect(to: host),
                           "\(host) is the operator's network, not the suite's")
        }
    }

    /// Loopback is decided by the address, not by something that merely
    /// looks like it.
    func testLookalikesAreNotLoopback() {
        for host in ["127.0.0.1.example.com", "1270.0.0.1", "localhost.attacker.net",
                     "12.7.0.1", "::2"] {
            XCTAssertFalse(AppEnvironment.isLoopback(host), host)
        }
    }

    /// A `--test-mode` instance is a real app pointed at the docker rig and
    /// has to reach it. Only an XCTest host is confined.
    func testTheRigInstanceIsNotConfined() {
        XCTAssertNotEqual(AppEnvironment.isUnitTestHost, AppEnvironment.isTestMode == false,
                          "isUnitTestHost must be the narrower of the two")
    }
}
