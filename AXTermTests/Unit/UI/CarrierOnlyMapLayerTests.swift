import XCTest
@testable import AXTerm

/// Layers that only draw from their own family's radios are not offered on a
/// station where no radio can carry that family.
///
/// A station whose one radio is a TNC4 on 144.390, marked as on an APRS
/// channel, showed a "Packet Coverage Rings" switch that could never draw
/// anything: an APRS-channel radio never opens a session and never counts
/// toward the packet receive ring. Observed Paths stays, since digipeated
/// APRS paths are observed paths too.
final class CarrierOnlyMapLayerTests: XCTestCase {

    private let tnc4 = RadioID(rawValue: "tnc4")
    private let direwolf = RadioID(rawValue: "direwolf")
    private let packetRing = "stations.showsCoverageRing"

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = TestDefaults.make("CarrierOnlyMapLayerTests")
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    private func titles(_ scope: MapLayerScope, _ possible: Set<RadioTrafficFamily>) -> [String] {
        MapLayerCatalog.layers(in: scope, possible: possible).map(\.title)
    }

    // MARK: - Which families are possible

    func testOneAPRSChannelRadioRulesOutAX25() {
        XCTAssertEqual(
            RadioTrafficClassifier.possibleFamilies(radios: [tnc4], aprsChannels: [tnc4]),
            [.aprs])
    }

    func testAPacketRadioBesideItBringsAX25Back() {
        XCTAssertEqual(
            RadioTrafficClassifier.possibleFamilies(radios: [tnc4, direwolf], aprsChannels: [tnc4]),
            [.aprs, .ax25])
    }

    /// A packet radio that has heard nothing yet is not known, and its
    /// layers must stay or there is nothing to switch on when traffic comes.
    func testARadioOnAPacketChannelCanCarryEither() {
        XCTAssertEqual(
            RadioTrafficClassifier.possibleFamilies(radios: [direwolf], aprsChannels: []),
            Set(RadioTrafficFamily.allCases))
    }

    func testNoRadiosRulesNothingOut() {
        XCTAssertEqual(
            RadioTrafficClassifier.possibleFamilies(radios: [], aprsChannels: []),
            Set(RadioTrafficFamily.allCases))
    }

    // MARK: - Which layers are offered

    func testOnlyThePacketRingNeedsAPacketRadio() {
        let everything = titles(.everything, Set(RadioTrafficFamily.allCases))
        let aprsOnly = titles(.everything, [.aprs])

        XCTAssertEqual(Set(everything).subtracting(aprsOnly), ["Packet Coverage Rings"])
        for kept in ["Observed Paths", "Predicted Paths", "Node Directory",
                     "APRS Coverage Rings", "Cluster Markers"] {
            XCTAssertTrue(aprsOnly.contains(kept), "\(kept) is still useful on an APRS station")
        }
    }

    func testTheCollapsedCountLeavesOutWhatIsNotOffered() {
        let aprsOnly = MapLayerCatalog.summary(in: .families([.ax25]), possible: [.aprs],
                                               defaults: defaults)
        XCTAssertEqual(aprsOnly.total, 3)
        XCTAssertEqual(aprsOnly.on, 0, "the packet ring was the only one on by default")

        let both = MapLayerCatalog.summary(in: .families([.ax25]), defaults: defaults)
        XCTAssertEqual(both.total, 4)
    }

    func testAKeyOutsideTheCatalogIsAlwaysOffered() {
        XCTAssertTrue(MapLayerCatalog.isOffered(storageKey: "stations.falloffMinutes",
                                                possible: []))
    }

    // MARK: - From the radios in Settings

    private func settings(_ label: String) -> AppSettingsStore {
        let defaults = TestDefaults.make(label)
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "K0EPI"
        return settings
    }

    private func setChannel(_ channel: RadioChannel, _ id: RadioID, in settings: AppSettingsStore) {
        settings.updateRadio(id) {
            channel.apply(to: &$0)
            $0.enabled = false
        }
    }

    func testASingleAPRSRadioHidesThePacketRingAndAPacketRadioBringsItBack() throws {
        let settings = settings("CarrierOnlyAPRSThenPacket")
        let first = try XCTUnwrap(settings.activeRadios.first)
        setChannel(.aprs, first.id, in: settings)
        XCTAssertEqual(settings.activeRadios.count, 1)

        // The operator had switched the packet ring off before; that choice
        // must still be there afterwards.
        defaults.set(false, forKey: packetRing)

        var possible = RadioTrafficClassifier.possibleFamilies(of: settings.activeRadios)
        XCTAssertEqual(possible, [.aprs])
        XCTAssertFalse(MapLayerCatalog.isOffered(storageKey: packetRing, possible: possible))
        XCTAssertTrue(titles(.everything, possible).contains("Observed Paths"))

        let second = settings.addRadio()
        setChannel(.packet, second.id, in: settings)

        possible = RadioTrafficClassifier.possibleFamilies(of: settings.activeRadios)
        XCTAssertEqual(possible, [.aprs, .ax25])
        XCTAssertTrue(MapLayerCatalog.isOffered(storageKey: packetRing, possible: possible))
        XCTAssertEqual(defaults.object(forKey: packetRing) as? Bool, false,
                       "hiding the switch left the stored value alone")
    }

    func testTwoAPRSRadiosStillHideThePacketRing() throws {
        let settings = settings("CarrierOnlyTwoAPRS")
        let first = try XCTUnwrap(settings.activeRadios.first)
        setChannel(.aprs, first.id, in: settings)
        let second = settings.addRadio()
        setChannel(.aprs, second.id, in: settings)

        let possible = RadioTrafficClassifier.possibleFamilies(of: settings.activeRadios)
        XCTAssertEqual(possible, [.aprs])
        XCTAssertFalse(MapLayerCatalog.isOffered(storageKey: packetRing, possible: possible))
    }
}
