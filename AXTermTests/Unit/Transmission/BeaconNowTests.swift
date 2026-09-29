import XCTest
@testable import AXTerm

/// "Beacon my position now", from the map.
///
/// The button exists because the operator watching the map is the operator who
/// wants to send a position, and until now the only way to key one was three
/// levels into Settings. Its obstacle text exists because of the failure that
/// started this whole area: a beacon that could not be built returned silently,
/// and the operator reasonably concluded the app was broken when it was only
/// unconfigured.
@MainActor
final class BeaconNowTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "beacon-now-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func store() -> AppSettingsStore {
        AppSettingsStore(defaults: defaults)
    }

    /// The fresh-install case, and the one most likely to be hit: nothing is
    /// configured, so the menu has to say where to go rather than nothing.
    func testNoBeaconAnywhereNamesTheSetting() {
        let settings = store()
        for radio in settings.radios {
            settings.updateRadio(radio.id) { $0.beacon.enabled = false }
        }
        let why = SessionCoordinator().beaconObstacle(settings)
        XCTAssertNotNil(why)
        XCTAssertTrue(why?.contains("Settings") == true, "point at where to fix it: \(why ?? "nil")")
    }

    /// A text beacon with something to say is not blocked.
    func testAConfiguredBeaconHasNoObstacle() {
        let settings = store()
        settings.updateRadio(settings.radios[0].id) {
            $0.enabled = true
            $0.beacon.enabled = true
            $0.beacon.kind = .text
            $0.beacon.text = "K0EPI packet node"
            $0.beacon.path = ""
        }
        XCTAssertNil(SessionCoordinator().beaconObstacle(settings))
    }

    /// One working beacon is enough for the button to do something, so a
    /// second radio waiting on a GPS fix must not report the whole station as
    /// blocked. Complaining there would train the operator to ignore it.
    func testOneWorkingRadioIsEnough() {
        let settings = store()
        settings.updateRadio(settings.radios[0].id) {
            $0.enabled = true
            $0.beacon.enabled = true
            $0.beacon.kind = .text
            $0.beacon.text = "K0EPI packet node"
            $0.beacon.path = ""
        }
        let second = settings.addRadio()
        settings.updateRadio(second.id) {
            $0.enabled = true
            $0.beacon.enabled = true
            $0.beacon.kind = .aprsPosition
            $0.beacon.aprs = APRSPositionConfig()
        }
        XCTAssertNil(SessionCoordinator().beaconObstacle(settings),
                     "one radio can beacon, so the station can")
    }

    /// Every beacon blocked reports the first reason rather than a count: the
    /// operator needs something to act on, not a tally.
    func testEveryRadioBlockedReportsWhy() {
        let settings = store()
        settings.updateRadio(settings.radios[0].id) {
            $0.enabled = true
            $0.beacon.enabled = true
            $0.beacon.kind = .aprsPosition
            $0.beacon.aprs = APRSPositionConfig()
        }
        let why = SessionCoordinator().beaconObstacle(settings)
        XCTAssertNotNil(why, "an APRS beacon with no position cannot go out")
    }

    /// A switched-off radio's beacon is not an obstacle — it is not part of
    /// the station right now.
    func testADisabledRadioIsNotCounted() {
        let settings = store()
        settings.updateRadio(settings.radios[0].id) {
            $0.enabled = true
            $0.beacon.enabled = true
            $0.beacon.kind = .text
            $0.beacon.text = "K0EPI packet node"
            $0.beacon.path = ""
        }
        let second = settings.addRadio()
        settings.updateRadio(second.id) {
            $0.enabled = false
            $0.beacon.enabled = true
            $0.beacon.kind = .aprsPosition
            $0.beacon.aprs = APRSPositionConfig()
        }
        XCTAssertNil(SessionCoordinator().beaconObstacle(settings))
    }
}
