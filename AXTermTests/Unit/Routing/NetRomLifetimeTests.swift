import XCTest
import GRDB
@testable import AXTerm

/// The routing objects have to be able to go away.
///
/// Each of these carried a `private static var retainedForTests` that the
/// initialiser appended `self` to. Nothing ever read it and nothing ever
/// cleared it, so in any DEBUG build — the test bundle, and the app running
/// under Xcode — every router, inference engine, persistence handle and
/// integration ever constructed was kept alive for the life of the process.
///
/// For the app that is a leak. For the suite it was worse: every test's
/// database handle stayed open behind a live `NetRomPersistence`, and the
/// broadcast integration tests failed intermittently in a full run while
/// passing every time on their own (2026-09-17).
@MainActor
final class NetRomLifetimeTests: XCTestCase {

    func testAnIntegrationIsReleasedWhenTheTestLetsGo() {
        weak var weakRef: NetRomIntegration?
        var integration: NetRomIntegration? =
            NetRomIntegration(localCallsign: "W0TST", mode: .classic)
        weakRef = integration
        XCTAssertNotNil(weakRef)

        integration = nil

        XCTAssertNil(weakRef, "a NetRomIntegration outlived its only owner")
    }

    func testARouterIsReleasedWhenTheTestLetsGo() {
        weak var weakRef: NetRomRouter?
        var router: NetRomRouter? = NetRomRouter(localCallsign: "W0TST")
        weakRef = router

        router = nil

        XCTAssertNil(weakRef, "a NetRomRouter outlived its only owner")
    }

    func testPassiveInferenceIsReleasedWhenTheTestLetsGo() {
        let router = NetRomRouter(localCallsign: "W0TST")
        weak var weakRef: NetRomPassiveInference?
        var inference: NetRomPassiveInference? =
            NetRomPassiveInference(router: router, localCallsign: "W0TST")
        weakRef = inference

        inference = nil

        XCTAssertNil(weakRef, "a NetRomPassiveInference outlived its only owner")
    }

    /// The one that mattered most: this holds a database handle open.
    func testPersistenceIsReleasedWhenTheTestLetsGo() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        weak var weakRef: NetRomPersistence?
        var persistence: NetRomPersistence? = try NetRomPersistence(database: queue)
        weakRef = persistence

        persistence = nil

        XCTAssertNil(weakRef, "a NetRomPersistence kept its database handle open")
    }
}
