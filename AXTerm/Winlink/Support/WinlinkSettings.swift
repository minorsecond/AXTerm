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

    static let defaultMaxDistanceMiles = 100
    static let defaultHistoryHours = 24

    static let passwordAccount = "winlink-password"
    static let apiKeyAccount = "winlink-cms-api-key"

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
    }
}
