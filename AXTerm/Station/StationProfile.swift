import Foundation
import Combine

/// The operator's identity: name, contact details, and mailing address.
///
/// This is app-wide station data (not Winlink-specific): it auto-fills
/// Winlink forms (ICS-213 "From", Check-in "Contact Name", Severe WX
/// "Reporting Party"/phone/email, FSR "POC"), signature blocks, and any
/// future BBS features. The Winlink password is *only* a credential —
/// the CMS never shares account identity over B2F, so these fields are
/// the local source of truth.
@MainActor
final class StationProfile: ObservableObject {

    static let realNameKey = "stationProfileRealName"
    static let positionTitleKey = "stationProfilePositionTitle"
    static let organizationKey = "stationProfileOrganization"
    static let phoneKey = "stationProfilePhone"
    static let emailKey = "stationProfileEmail"
    static let streetKey = "stationProfileStreet"
    static let cityKey = "stationProfileCity"
    static let stateKey = "stationProfileState"
    static let postalCodeKey = "stationProfilePostalCode"
    static let countyKey = "stationProfileCounty"

    @Published var realName: String { didSet { defaults.set(realName, forKey: Self.realNameKey) } }
    @Published var positionTitle: String { didSet { defaults.set(positionTitle, forKey: Self.positionTitleKey) } }
    @Published var organization: String { didSet { defaults.set(organization, forKey: Self.organizationKey) } }
    @Published var phone: String { didSet { defaults.set(phone, forKey: Self.phoneKey) } }
    @Published var email: String { didSet { defaults.set(email, forKey: Self.emailKey) } }
    @Published var street: String { didSet { defaults.set(street, forKey: Self.streetKey) } }
    @Published var city: String { didSet { defaults.set(city, forKey: Self.cityKey) } }
    @Published var state: String { didSet { defaults.set(state, forKey: Self.stateKey) } }
    @Published var postalCode: String { didSet { defaults.set(postalCode, forKey: Self.postalCodeKey) } }
    @Published var county: String { didSet { defaults.set(county, forKey: Self.countyKey) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        realName = defaults.string(forKey: Self.realNameKey) ?? ""
        positionTitle = defaults.string(forKey: Self.positionTitleKey) ?? ""
        organization = defaults.string(forKey: Self.organizationKey) ?? ""
        phone = defaults.string(forKey: Self.phoneKey) ?? ""
        email = defaults.string(forKey: Self.emailKey) ?? ""
        street = defaults.string(forKey: Self.streetKey) ?? ""
        city = defaults.string(forKey: Self.cityKey) ?? ""
        state = defaults.string(forKey: Self.stateKey) ?? ""
        postalCode = defaults.string(forKey: Self.postalCodeKey) ?? ""
        county = defaults.string(forKey: Self.countyKey) ?? ""
    }

    /// "Jane Doe, EC" or "Jane Doe" or "" — for form From/POC fields.
    var nameWithTitle: String {
        switch (realName.isEmpty, positionTitle.isEmpty) {
        case (false, false): return "\(realName), \(positionTitle)"
        case (false, true): return realName
        default: return ""
        }
    }

    /// Multi-line contact block for signatures and welfare forms.
    var contactBlock: String {
        var lines = [String]()
        if !realName.isEmpty { lines.append(realName) }
        if !organization.isEmpty { lines.append(organization) }
        if !street.isEmpty { lines.append(street) }
        let cityLine = [city, state, postalCode].filter { !$0.isEmpty }.joined(separator: ", ")
        if !cityLine.isEmpty { lines.append(cityLine) }
        if !phone.isEmpty { lines.append(phone) }
        if !email.isEmpty { lines.append(email) }
        return lines.joined(separator: "\r\n")
    }
}
