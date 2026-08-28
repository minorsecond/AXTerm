import Foundation
import Combine

/// Winlink feature settings. Non-secret values follow the
/// `AppSettingsStore` key-constant + persist pattern in a feature-local
/// store; the account password and CMS access key live in the Keychain.
@MainActor
final class WinlinkSettings: ObservableObject {

    // MARK: - Keys

    static let gridSquareKey = "winlinkGridSquare"
    static let antennaHeightMetresKey = "stationAntennaHeightMetres"
    static let assumedRemoteHeightMetresKey = "stationAssumedRemoteHeightMetres"
    static let heightUnitIsFeetKey = "stationHeightUnitIsFeet"
    static let shareStationActivityKey = "winlinkShareStationActivity"
    static let maxDistanceMilesKey = "winlinkMaxDistanceMiles"
    static let historyHoursKey = "winlinkHistoryHours"
    static let gatewayCallsignKey = "winlinkGatewayCallsign"
    static let gatewayPathKey = "winlinkGatewayPath"
    static let p2pListenEnabledKey = "winlinkP2PListenEnabled"
    static let p2pListenCallsignKey = "winlinkP2PListenCallsign"
    static let stationPreferencesKey = "winlinkStationPreferences"
    static let callsignLookupEnabledKey = "winlinkCallsignLookupEnabled"
    static let preferredTransportKey = "winlinkPreferredTransport"
    static let clientProductKey = "winlinkClientProduct"
    static let gatewayLadderKey = "winlinkGatewayLadder"
    static let mailboxSyncEnabledKey = "winlinkMailboxSyncEnabled"

    static let defaultMaxDistanceMiles = 100
    static let defaultHistoryHours = 24

    static let passwordAccount = "winlink-password"
    static let apiKeyAccount = "winlink-cms-api-key"

    /// One rung of the RF gateway ladder. A rung identifies a specific
    /// gateway port: callsign plus (optionally) the advertised frequency,
    /// so a multi-port station like W0ARP-10 on 145.030/145.050/441.075
    /// can be laddered per port. frequencyHz nil (manual entries and
    /// pre-frequency ladders) matches any port of that callsign.
    nonisolated struct GatewayLadderEntry: Codable, Equatable, Identifiable, Sendable {
        var callsign: String
        var path: String = ""
        var frequencyHz: Int?
        var id: String { "\(callsign)@\(frequencyHz ?? 0)" }

        func matches(callsign: String, frequencyHz: Int) -> Bool {
            guard self.callsign == callsign.uppercased() else { return false }
            guard let own = self.frequencyHz else { return true }
            return own == frequencyHz
        }
    }

    enum TransportPreference: String, CaseIterable {
        case ax25
        case telnet
    }

    // MARK: - Published settings

    /// Maidenhead locator of the station (needed for the proximity query).
    @Published var gridSquare: String {
        didSet { defaults.set(gridSquare, forKey: Self.gridSquareKey) }
    }

    /// Height of this station's antenna above the ground beneath it, in
    /// metres.
    ///
    /// Not decoration: this is the single input that most often decides a
    /// terrain verdict. Sixty percent Fresnel clearance over 13 km at 145 MHz
    /// needs roughly 49 m of height, and the same path from 10 m clears about
    /// 9% of the zone. Getting this wrong by a factor of five changes every
    /// forecast the station appears in.
    ///
    /// Above *ground*, not above sea level — the elevation data supplies the
    /// ground, and adding sea level twice would put every antenna in orbit.
    @Published var antennaHeightMetres: Double {
        didSet { defaults.set(antennaHeightMetres, forKey: Self.antennaHeightMetresKey) }
    }

    /// What to assume for a station whose height nobody has recorded.
    ///
    /// Kept separate from the operator's own height and shown wherever a
    /// forecast is, because it is an assumption rather than a measurement and
    /// a forecast built on it should say so. Ten metres is a modest mast, not
    /// a repeater site.
    @Published var assumedRemoteHeightMetres: Double {
        didSet { defaults.set(assumedRemoteHeightMetres, forKey: Self.assumedRemoteHeightMetresKey) }
    }

    /// Feet in the field, metres in the maths.
    ///
    /// Heights are stored in metres because the propagation formulas are
    /// metric, but a US operator knows their tower in feet and converting in
    /// their head is how a 40 ft mast gets entered as 40 m.
    @Published var heightUnitIsFeet: Bool {
        didSet { defaults.set(heightUnitIsFeet, forKey: Self.heightUnitIsFeetKey) }
    }

    /// Publish what this station hears to the operator's other stations.
    ///
    /// Off by default. It tells iCloud which stations this receiver can
    /// hear, which is a rough statement about where the operator is and
    /// when they are on the air — the same reasoning that keeps callsign
    /// lookup opt-in. What arrives is only ever displayed as another
    /// station's evidence; see `WinlinkSyncPolicy.attributed`.
    @Published var shareStationActivity: Bool {
        didSet { defaults.set(shareStationActivity, forKey: Self.shareStationActivityKey) }
    }

    @Published var maxDistanceMiles: Int {
        didSet { defaults.set(maxDistanceMiles, forKey: Self.maxDistanceMilesKey) }
    }

    @Published var historyHours: Int {
        didSet { defaults.set(historyHours, forKey: Self.historyHoursKey) }
    }

    /// Preferred RMS gateway ("KE7XO-10"), set from the stations list.
    @Published var gatewayCallsign: String {
        didSet { defaults.set(gatewayCallsign, forKey: Self.gatewayCallsignKey) }
    }

    /// Optional digipeater path to the gateway ("WIDE1-1" style, comma separated).
    @Published var gatewayPath: String {
        didSet { defaults.set(gatewayPath, forKey: Self.gatewayPathKey) }
    }

    @Published var preferredTransport: TransportPreference {
        didSet { defaults.set(preferredTransport.rawValue, forKey: Self.preferredTransportKey) }
    }

    /// Answer inbound Winlink calls as a P2P mail peer.
    ///
    /// Off by default and deliberately so: an armed station accepts mail
    /// from anyone who calls, and transmits in reply, with no operator
    /// present. That is what an activation needs and what ordinary
    /// operating does not, so arming stays a decision rather than a
    /// default. See `WinlinkP2PListener`.
    @Published var p2pListenEnabled: Bool {
        didSet { defaults.set(p2pListenEnabled, forKey: Self.p2pListenEnabledKey) }
    }

    /// The callsign P2P answers on, SSID included. Empty means the station
    /// callsign, which is what it has always used.
    ///
    /// This is an *address*, not an identity: the Winlink account and the
    /// callsign carried in B2F stay the station's. Giving the listener its own
    /// SSID is only what lets it share a radio with another service — a
    /// mailbox, or a node on the same host — since a caller picks the service
    /// by the callsign they dial.
    @Published var p2pListenCallsign: String {
        didSet { defaults.set(p2pListenCallsign, forKey: Self.p2pListenCallsignKey) }
    }

    /// The address P2P actually answers on, given the station callsign.
    func effectiveP2PCallsign(stationCallsign: String) -> String {
        let own = p2pListenCallsign.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? stationCallsign.uppercased() : own.uppercased()
    }

    /// Look up callsigns in an online directory (HamDB) to place heard
    /// stations on the map.
    ///
    /// Off by default: a lookup tells a third party which stations this
    /// operator is hearing. Public licence data, a small disclosure — but
    /// a disclosure, and not one to make silently. Answers are cached
    /// permanently, so this is a "fill it while you have a path" feature.
    @Published var callsignLookupEnabled: Bool {
        didSet { defaults.set(callsignLookupEnabled, forKey: Self.callsignLookupEnabledKey) }
    }

    /// Per-link digipeater paths and table visibility. See
    /// `WinlinkStationPreferences`.
    @Published var stationPreferences: WinlinkStationPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(stationPreferences) {
                defaults.set(data, forKey: Self.stationPreferencesKey)
            }
        }
    }

    /// Ordered RF gateway ladder: Connect & Exchange tries each entry
    /// top-down until a session succeeds. The first entry is the
    /// "favorite"/primary gateway.
    @Published var gatewayLadder: [GatewayLadderEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(gatewayLadder) {
                defaults.set(String(data: data, encoding: .utf8), forKey: Self.gatewayLadderKey)
            }
            // Keep the legacy single-gateway fields mirroring the top rung.
            let top = gatewayLadder.first
            if gatewayCallsign != (top?.callsign ?? "") { gatewayCallsign = top?.callsign ?? "" }
            if gatewayPath != (top?.path ?? "") { gatewayPath = top?.path ?? "" }
        }
    }

    // MARK: - Ladder operations

    func addToLadder(callsign: String, path: String = "", frequencyHz: Int? = nil) {
        let normalized = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !normalized.isEmpty else { return }
        let entry = GatewayLadderEntry(callsign: normalized, path: path, frequencyHz: frequencyHz)
        guard !gatewayLadder.contains(where: { $0.id == entry.id }) else { return }
        gatewayLadder.append(entry)
    }

    func removeFromLadder(entryID: String) {
        gatewayLadder.removeAll { $0.id == entryID }
    }

    func promoteToTop(entryID: String) {
        guard let index = gatewayLadder.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = gatewayLadder.remove(at: index)
        gatewayLadder.insert(entry, at: 0)
    }

    func moveInLadder(entryID: String, up: Bool) {
        guard let index = gatewayLadder.firstIndex(where: { $0.id == entryID }) else { return }
        let target = up ? index - 1 : index + 1
        guard gatewayLadder.indices.contains(target) else { return }
        gatewayLadder.swapAt(index, target)
    }

    /// Rank of the rung matching this specific gateway port, if any.
    func ladderRank(callsign: String, frequencyHz: Int) -> Int? {
        gatewayLadder.firstIndex { $0.matches(callsign: callsign, frequencyHz: frequencyHz) }
            .map { $0 + 1 }
    }

    /// SID product name sent in the B2F handshake. The production CMS
    /// whitelists client types and refuses unknown ones ("Unknown client
    /// types are not allowed"), so until "AXTerm" is registered with the
    /// Winlink team, a registered product name can be selected instead.
    @Published var clientProduct: String {
        didSet { defaults.set(clientProduct, forKey: Self.clientProductKey) }
    }

    /// Whether the mailbox replicates to this operator's other devices.
    ///
    /// On by default for a new station, off for anyone who has turned it
    /// off. Mail is the one thing an operator expects to find on whichever
    /// device they pick up; the measurements are not, and never travel.
    /// See Docs/UnifiedMailbox.md for exactly what does and does not.
    @Published var mailboxSyncEnabled: Bool {
        didSet { defaults.set(mailboxSyncEnabled, forKey: Self.mailboxSyncEnabledKey) }
    }

    // MARK: - Keychain-backed credentials

    private let keychain: KeychainStore

    /// Saves the password and verifies it by reading it back — the only
    /// way to catch a Keychain that accepts the write but denies reads
    /// (seen after rebuilds when the code signature changes).
    @discardableResult
    func savePasswordVerified(_ value: String) -> Bool {
        password = value
        return password == value
    }

    /// Winlink account password (used for `;PR:` secure login).
    var password: String {
        get { keychain.string(account: Self.passwordAccount) ?? "" }
        set {
            objectWillChange.send()
            if newValue.isEmpty {
                keychain.remove(account: Self.passwordAccount)
            } else {
                keychain.setString(newValue, account: Self.passwordAccount)
            }
        }
    }

    /// CMS web-services access key. Empty means "use the built-in default".
    var apiKeyOverride: String {
        get { keychain.string(account: Self.apiKeyAccount) ?? "" }
        set {
            objectWillChange.send()
            if newValue.isEmpty {
                keychain.remove(account: Self.apiKeyAccount)
            } else {
                keychain.setString(newValue, account: Self.apiKeyAccount)
            }
        }
    }

    var effectiveAPIKey: String {
        let override = apiKeyOverride
        return override.isEmpty ? WinlinkCMSClient.defaultAccessKey : override
    }

    // MARK: - Init

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain

        gridSquare = defaults.string(forKey: Self.gridSquareKey) ?? ""
        // `double(forKey:)` returns 0 for a key that was never set, which as
        // an antenna height means "on the ground" — a real value that would
        // silently blockade every path. Nil-coalesce through `object` so an
        // unset key falls back to the default instead.
        antennaHeightMetres = (defaults.object(forKey: Self.antennaHeightMetresKey)
            as? Double) ?? 10
        assumedRemoteHeightMetres = (defaults.object(forKey: Self.assumedRemoteHeightMetresKey)
            as? Double) ?? 10
        heightUnitIsFeet = (defaults.object(forKey: Self.heightUnitIsFeetKey)
            as? Bool) ?? true
        shareStationActivity = defaults.bool(forKey: Self.shareStationActivityKey)
        maxDistanceMiles = defaults.object(forKey: Self.maxDistanceMilesKey) as? Int ?? Self.defaultMaxDistanceMiles
        historyHours = defaults.object(forKey: Self.historyHoursKey) as? Int ?? Self.defaultHistoryHours
        gatewayCallsign = defaults.string(forKey: Self.gatewayCallsignKey) ?? ""
        gatewayPath = defaults.string(forKey: Self.gatewayPathKey) ?? ""
        p2pListenEnabled = defaults.bool(forKey: Self.p2pListenEnabledKey)
        p2pListenCallsign = defaults.string(forKey: Self.p2pListenCallsignKey) ?? ""
        callsignLookupEnabled = defaults.bool(forKey: Self.callsignLookupEnabledKey)
        // On for a fresh install, because a mailbox that does not follow the
        // operator between their own devices is the thing they notice first.
        // `bool(forKey:)` cannot tell "never set" from "set to false", so the
        // presence of the key is what distinguishes a new station from one
        // that has already chosen.
        //
        // Note this does send mail to Apple's servers. An operator who has
        // already turned it off keeps it off — the default applies only where
        // no decision exists yet — and Settings → Winlink turns it off again.
        mailboxSyncEnabled = defaults.object(forKey: Self.mailboxSyncEnabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.mailboxSyncEnabledKey)
        stationPreferences = defaults.data(forKey: Self.stationPreferencesKey)
            .flatMap { try? JSONDecoder().decode(WinlinkStationPreferences.self, from: $0) }
            ?? WinlinkStationPreferences()
        preferredTransport = TransportPreference(
            rawValue: defaults.string(forKey: Self.preferredTransportKey) ?? "") ?? .ax25
        clientProduct = defaults.string(forKey: Self.clientProductKey) ?? "AXTerm"

        if let json = defaults.string(forKey: Self.gatewayLadderKey),
           let data = json.data(using: .utf8),
           let entries = try? JSONDecoder().decode([GatewayLadderEntry].self, from: data) {
            gatewayLadder = entries
        } else if let legacy = defaults.string(forKey: Self.gatewayCallsignKey), !legacy.isEmpty {
            // Migrate the pre-ladder single gateway into rung 1.
            gatewayLadder = [GatewayLadderEntry(
                callsign: legacy,
                path: defaults.string(forKey: Self.gatewayPathKey) ?? "")]
        } else {
            gatewayLadder = []
        }
    }
}
