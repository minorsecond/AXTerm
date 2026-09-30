import XCTest
@testable import AXTerm

/// The station callsign is the base call; each radio carries its own SSID.
///
/// Covers the migration that moves an SSID stored by an older build onto the
/// radios, the General field refusing to store one, the radios following a
/// corrected base, and the single radio getting its own Identity section.
@MainActor
final class StationCallsignRulesTests: XCTestCase {

    // MARK: - Helpers

    private func defaults(station: String?, radios: [RadioProfile]?) -> UserDefaults {
        let defaults = TestDefaults.make("StationCallsignRules")
        if let station { defaults.set(station, forKey: AppSettingsStore.myCallsignKey) }
        if let radios {
            let json = String(data: try! JSONEncoder().encode(radios), encoding: .utf8)!
            defaults.set(json, forKey: AppSettingsStore.radiosKey)
        }
        return defaults
    }

    private func storedRadios(_ defaults: UserDefaults) -> [RadioProfile] {
        guard let json = defaults.string(forKey: AppSettingsStore.radiosKey),
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RadioProfile].self, from: data)) ?? []
    }

    private func radio(_ name: String, id: RadioID = RadioID(), callsign: String = "") -> RadioProfile {
        var radio = RadioProfile(id: id, name: name)
        radio.callsign = callsign
        return radio
    }

    // MARK: - Migration

    func testAStoredSSIDMovesToEveryRadioThatInheritedIt() {
        let inheriting = radio("VHF", id: .primary)
        let club = radio("Club", callsign: "W0CLB-1")
        let alsoInheriting = radio("UHF")
        let defaults = defaults(station: "K0EPI-5", radios: [inheriting, club, alsoInheriting])

        let settings = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(settings.myCallsign, "K0EPI")
        XCTAssertEqual(settings.radio(inheriting.id)?.callsign, "K0EPI-5")
        XCTAssertEqual(settings.radio(alsoInheriting.id)?.callsign, "K0EPI-5")
        XCTAssertEqual(settings.radio(club.id)?.callsign, "W0CLB-1",
                       "a radio with a callsign of its own keeps it")
    }

    func testNothingChangesOnTheAir() {
        let inheriting = radio("VHF", id: .primary)
        let club = radio("Club", callsign: "W0CLB-1")
        let before = [inheriting, club].map { $0.resolvedCallsign(station: "K0EPI-5") }

        let settings = AppSettingsStore(defaults: defaults(station: "K0EPI-5", radios: [inheriting, club]))

        let after = settings.radios.map { $0.resolvedCallsign(station: settings.myCallsign) }
        XCTAssertEqual(after, before)
        XCTAssertEqual(settings.primaryCallsign, "K0EPI-5",
                       "the primary radio's address is what the station callsign was")
    }

    func testTheMigrationIsPersisted() {
        let inheriting = radio("VHF", id: .primary)
        let defaults = defaults(station: "K0EPI-5", radios: [inheriting])

        _ = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: AppSettingsStore.myCallsignKey), "K0EPI")
        XCTAssertEqual(storedRadios(defaults).first?.callsign, "K0EPI-5")
    }

    func testTheMigrationRunsOnce() {
        let inheriting = radio("VHF", id: .primary)
        let defaults = defaults(station: "K0EPI-5", radios: [inheriting])
        _ = AppSettingsStore(defaults: defaults)
        let firstRadios = defaults.string(forKey: AppSettingsStore.radiosKey)

        let second = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(second.myCallsign, "K0EPI")
        XCTAssertEqual(second.radios.first?.callsign, "K0EPI-5")
        XCTAssertEqual(defaults.string(forKey: AppSettingsStore.radiosKey), firstRadios,
                       "a second launch finds a bare base and writes nothing new")
    }

    func testSSIDZeroIsNoSuffix() {
        let inheriting = radio("VHF", id: .primary)

        let settings = AppSettingsStore(defaults: defaults(station: "K0EPI-0", radios: [inheriting]))

        XCTAssertEqual(settings.myCallsign, "K0EPI")
        XCTAssertEqual(settings.radios.first?.callsign, "", "SSID 0 leaves the radio inheriting")
        XCTAssertEqual(settings.primaryCallsign, "K0EPI")
    }

    func testABareCallsignIsLeftAlone() {
        let inheriting = radio("VHF", id: .primary)

        let settings = AppSettingsStore(defaults: defaults(station: "K0EPI", radios: [inheriting]))

        XCTAssertEqual(settings.myCallsign, "K0EPI")
        XCTAssertEqual(settings.radios.first?.callsign, "")
    }

    func testNoCallsignSetChangesNothing() {
        let inheriting = radio("VHF", id: .primary)
        let defaults = defaults(station: nil, radios: [inheriting])

        let settings = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(settings.myCallsign, "")
        XCTAssertEqual(settings.radios.first?.callsign, "")
        XCTAssertEqual(settings.primaryCallsign, "")
    }

    func testALegacyInstallWithNoRadioListGetsTheSSIDOnItsOneRadio() {
        let defaults = defaults(station: "k0epi-7", radios: nil)

        let settings = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(settings.myCallsign, "K0EPI")
        XCTAssertEqual(settings.radios.count, 1)
        XCTAssertEqual(settings.radios.first?.callsign, "K0EPI-7")
        XCTAssertEqual(storedRadios(defaults).first?.callsign, "K0EPI-7")
    }

    func testASuffixThatIsNotAnSSIDIsCarriedAsItWas() {
        var radios = [radio("VHF", id: .primary)]
        let split = StationCallsignRules.splitStoredStation("K0EPI-X", radios: &radios)

        XCTAssertEqual(split.base, "K0EPI")
        XCTAssertTrue(split.radiosChanged)
        XCTAssertEqual(radios.first?.callsign, "K0EPI-X")
    }

    // MARK: - The General field

    func testTheStationCallsignNeverStoresAnSSID() {
        let defaults = defaults(station: nil, radios: nil)
        let settings = AppSettingsStore(defaults: defaults)

        settings.myCallsign = "k0epi-5"

        XCTAssertEqual(settings.myCallsign, "K0EPI")
        XCTAssertEqual(defaults.string(forKey: AppSettingsStore.myCallsignKey), "K0EPI")
        XCTAssertEqual(settings.radios.first?.callsign, "",
                       "typing an SSID in General does not reach into a radio")
    }

    func testTheFieldSaysWhereTheSSIDGoesWithOneRadio() throws {
        let guidance = try XCTUnwrap(StationCallsignRules.ssidGuidance(for: "k0epi-5", hasMultipleRadios: false))
        XCTAssertTrue(guidance.contains("Only K0EPI is kept"), guidance)
        XCTAssertTrue(guidance.contains("K0EPI-5"), guidance)
        XCTAssertTrue(guidance.contains("Identity"), guidance)
        XCTAssertTrue(guidance.contains("Connection"), guidance)
    }

    func testTheFieldSaysWhereTheSSIDGoesWithSeveralRadios() throws {
        let guidance = try XCTUnwrap(StationCallsignRules.ssidGuidance(for: "K0EPI-5", hasMultipleRadios: true))
        XCTAssertTrue(guidance.contains("per radio"), guidance)
        XCTAssertTrue(guidance.contains("Radios"), guidance)
    }

    func testABareCallsignNeedsNoGuidance() {
        XCTAssertNil(StationCallsignRules.ssidGuidance(for: "K0EPI", hasMultipleRadios: false))
        XCTAssertNil(StationCallsignRules.ssidGuidance(for: "", hasMultipleRadios: true))
    }

    // MARK: - Radios follow a corrected base

    func testCorrectingTheBaseMovesTheRadiosSetUnderIt() {
        let vhf = radio("VHF", id: .primary, callsign: "K0EPX-5")
        let club = radio("Club", callsign: "W0CLB-1")
        let fresh = radio("Fresh")
        let bare = radio("Bare", callsign: "K0EPX")
        let settings = AppSettingsStore(defaults: defaults(station: "K0EPX", radios: [vhf, club, fresh, bare]))

        settings.myCallsign = "K0EPI"

        XCTAssertEqual(settings.radio(vhf.id)?.callsign, "K0EPI-5")
        XCTAssertEqual(settings.radio(bare.id)?.callsign, "K0EPI")
        XCTAssertEqual(settings.radio(club.id)?.callsign, "W0CLB-1", "another identity is not touched")
        XCTAssertEqual(settings.radio(fresh.id)?.callsign, "", "an inheriting radio follows by itself")
    }

    func testClearingTheFieldAndTypingAgainFindsTheRadios() {
        let vhf = radio("VHF", id: .primary, callsign: "K0EPI-5")
        let settings = AppSettingsStore(defaults: defaults(station: "K0EPI", radios: [vhf]))

        settings.myCallsign = ""
        XCTAssertEqual(settings.radios.first?.callsign, "K0EPI-5", "an empty base moves nothing")
        settings.myCallsign = "W1ABC"

        XCTAssertEqual(settings.radios.first?.callsign, "W1ABC-5")
    }

    // MARK: - --callsign in test mode

    func testAdoptingATypedCallsignSplitsItOntoTheRadios() {
        let settings = AppSettingsStore(defaults: defaults(station: nil, radios: nil))

        settings.adoptStationCallsign("TEST-2")

        XCTAssertEqual(settings.myCallsign, "TEST")
        XCTAssertEqual(settings.radios.first?.callsign, "TEST-2")
        XCTAssertEqual(settings.primaryCallsign, "TEST-2")
    }

    func testAdoptingIsIdempotent() {
        let settings = AppSettingsStore(defaults: defaults(station: nil, radios: nil))
        settings.adoptStationCallsign("TEST-2")
        settings.adoptStationCallsign("TEST-2")

        XCTAssertEqual(settings.radios.first?.callsign, "TEST-2")
    }

    // MARK: - On-air identity

    func testEachRadioGoesOnTheAirUnderItsOwnSSID() {
        let vhf = radio("VHF", id: .primary, callsign: "K0EPI-5")
        let uhf = radio("UHF", callsign: "K0EPI-7")
        let settings = AppSettingsStore(defaults: defaults(station: "K0EPI", radios: [vhf, uhf]))

        XCTAssertEqual(settings.onAirCallsign(for: vhf.id), "K0EPI-5")
        XCTAssertEqual(settings.onAirCallsign(for: uhf.id), "K0EPI-7")
        XCTAssertEqual(settings.onAirCallsign(for: nil), "K0EPI-5", "no radio named: the primary")
        XCTAssertEqual(settings.onAirCallsign(for: RadioID(rawValue: "gone")), "K0EPI-5")
        XCTAssertEqual(settings.onAirCallsigns, ["K0EPI-5", "K0EPI-7"],
                       "the bare base is not an address any radio transmits as")
    }

    func testAFreshRadioGoesOnTheAirAsTheBase() {
        let settings = AppSettingsStore(defaults: defaults(station: "K0EPI", radios: nil))
        XCTAssertEqual(settings.onAirCallsigns, ["K0EPI"])
    }

    func testTheStoredPrimaryCallsignMatchesTheStore() {
        let vhf = radio("VHF", id: .primary, callsign: "K0EPI-5")
        let defaults = defaults(station: "K0EPI", radios: [vhf])
        let settings = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(StationCallsignRules.storedPrimaryCallsign(defaults: defaults),
                       settings.primaryCallsign)
    }

    // MARK: - The radio page

    func testASingleRadioShowsItsIdentity() {
        XCTAssertTrue(RadioDetailView.showsIdentity(hasMultipleRadios: false, page: .connection),
                      "one radio has one page, and its SSID picker is on it")
        XCTAssertTrue(RadioDetailView.showsIdentity(hasMultipleRadios: true, page: .onAir))
        XCTAssertFalse(RadioDetailView.showsIdentity(hasMultipleRadios: true, page: .connection))
    }
}
