import Foundation
import Combine

/// Winlink feature settings. Non-secret values follow the
/// `AppSettingsStore` key-constant + persist pattern in a feature-local
/// store; the account password and CMS access key live in the Keychain.
@MainActor
final class WinlinkSettings: ObservableObject {

    // MARK: - Keys

    static let gridSquareKey = "winlinkGridSquare"
    static let maxDistanceMilesKey = "winlinkMaxDistanceMiles"
    static let historyHoursKey = "winlinkHistoryHours"
    static let gatewayCallsignKey = "winlinkGatewayCallsign"
    static let gatewayPathKey = "winlinkGatewayPath"
    static let preferredTransportKey = "winlinkPreferredTransport"
    static let clientProductKey = "winlinkClientProduct"
    static let gatewayLadderKey = "winlinkGatewayLadder"

    static let defaultMaxDistanceMiles = 100
    static let defaultHistoryHours = 24

    static let passwordAccount = "winlink-password"
    static let apiKeyAccount = "winlink-cms-api-key"

    /// One rung of the RF gateway ladder.
    nonisolated struct GatewayLadderEntry: Codable, Equatable, Identifiable, Sendable {
        var callsign: String
        var path: String = ""
        var id: String { callsign }
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

    func addToLadder(callsign: String, path: String = "") {
        let normalized = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !normalized.isEmpty else { return }
        guard !gatewayLadder.contains(where: { $0.callsign == normalized }) else { return }
        gatewayLadder.append(GatewayLadderEntry(callsign: normalized, path: path))
    }

    func removeFromLadder(callsign: String) {
        gatewayLadder.removeAll { $0.callsign == callsign }
    }

    func promoteToTop(callsign: String) {
        guard let index = gatewayLadder.firstIndex(where: { $0.callsign == callsign }) else { return }
        let entry = gatewayLadder.remove(at: index)
        gatewayLadder.insert(entry, at: 0)
    }

    func moveInLadder(callsign: String, up: Bool) {
        guard let index = gatewayLadder.firstIndex(where: { $0.callsign == callsign }) else { return }
        let target = up ? index - 1 : index + 1
        guard gatewayLadder.indices.contains(target) else { return }
        gatewayLadder.swapAt(index, target)
    }

    func ladderContains(callsign: String) -> Bool {
        gatewayLadder.contains { $0.callsign == callsign.uppercased() }
    }

    func ladderRank(of callsign: String) -> Int? {
        gatewayLadder.firstIndex { $0.callsign == callsign.uppercased() }.map { $0 + 1 }
    }

    /// SID product name sent in the B2F handshake. The production CMS
    /// whitelists client types and refuses unknown ones ("Unknown client
    /// types are not allowed"), so until "AXTerm" is registered with the
    /// Winlink team, a registered product name can be selected instead.
    @Published var clientProduct: String {
        didSet { defaults.set(clientProduct, forKey: Self.clientProductKey) }
    }

    // MARK: - Keychain-backed credentials

    private let keychain: KeychainStore

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
        maxDistanceMiles = defaults.object(forKey: Self.maxDistanceMilesKey) as? Int ?? Self.defaultMaxDistanceMiles
        historyHours = defaults.object(forKey: Self.historyHoursKey) as? Int ?? Self.defaultHistoryHours
        gatewayCallsign = defaults.string(forKey: Self.gatewayCallsignKey) ?? ""
        gatewayPath = defaults.string(forKey: Self.gatewayPathKey) ?? ""
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
