import Foundation
import CoreLocation

/// A postal address derived from a position.
///
/// Winlink's welfare and situation-report forms ask for city, county and
/// state, and typing them by hand is both tedious and the kind of thing
/// an operator forgets before leaving. A GPS fix already knows where the
/// station is; this turns that into the fields the forms want.
///
/// **What needs the network and what does not.** A grid square is pure
/// arithmetic on the coordinates (`Maidenhead.locator`) and works with
/// everything else down. A *postal* address does not exist in the fix —
/// it requires a geocoding service, which requires the internet. So this
/// is something to fill in while a path exists, and the UI must say so
/// rather than failing mysteriously in the field.
nonisolated struct StationAddress: Equatable, Sendable {
    var street: String = ""
    var city: String = ""
    /// USPS abbreviation in the US; the region's own name elsewhere.
    var state: String = ""
    var postalCode: String = ""
    var county: String = ""

    var isEmpty: Bool {
        street.isEmpty && city.isEmpty && state.isEmpty
            && postalCode.isEmpty && county.isEmpty
    }

    /// The subset of a placemark this cares about, lifted out so the
    /// mapping can be tested without CoreLocation or a network.
    struct PlacemarkFields: Equatable, Sendable {
        var subThoroughfare: String?
        var thoroughfare: String?
        var locality: String?
        var administrativeArea: String?
        var subAdministrativeArea: String?
        var postalCode: String?

        init(subThoroughfare: String? = nil,
             thoroughfare: String? = nil,
             locality: String? = nil,
             administrativeArea: String? = nil,
             subAdministrativeArea: String? = nil,
             postalCode: String? = nil) {
            self.subThoroughfare = subThoroughfare
            self.thoroughfare = thoroughfare
            self.locality = locality
            self.administrativeArea = administrativeArea
            self.subAdministrativeArea = subAdministrativeArea
            self.postalCode = postalCode
        }
    }

    static func from(_ fields: PlacemarkFields) -> StationAddress {
        StationAddress(
            street: [fields.subThoroughfare, fields.thoroughfare]
                .compactMap { $0?.trimmed }
                .filter { !$0.isEmpty }
                .joined(separator: " "),
            city: fields.locality?.trimmed ?? "",
            state: fields.administrativeArea?.trimmed ?? "",
            // ICS forms want the county name, not "Jefferson County" —
            // the label beside the field already says County.
            postalCode: fields.postalCode?.trimmed ?? "",
            county: normalizedCounty(fields.subAdministrativeArea))
    }

    private static func normalizedCounty(_ raw: String?) -> String {
        guard let value = raw?.trimmed, !value.isEmpty else { return "" }
        for suffix in [" County", " Parish", " Borough"] where value.hasSuffix(suffix) {
            return String(value.dropLast(suffix.count)).trimmed
        }
        return value
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Resolution

/// Turns coordinates into a postal address using the system geocoder.
///
/// Deliberately thin: everything worth testing lives in
/// `StationAddress.from(_:)`, and this is the untestable edge that talks
/// to Apple's service.
@MainActor
final class StationAddressResolver {

    enum ResolveError: LocalizedError {
        case noResult
        case offline(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .noResult:
                "No address is known for this position."
            case .offline:
                "Looking up an address needs an internet connection. The grid square was set from GPS and does not."
            }
        }
    }

    private let geocoder = CLGeocoder()

    func address(latitude: Double, longitude: Double) async throws -> StationAddress {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let placemarks: [CLPlacemark]
        do {
            placemarks = try await geocoder.reverseGeocodeLocation(location)
        } catch {
            throw ResolveError.offline(underlying: error)
        }
        guard let placemark = placemarks.first else { throw ResolveError.noResult }
        return StationAddress.from(.init(
            subThoroughfare: placemark.subThoroughfare,
            thoroughfare: placemark.thoroughfare,
            locality: placemark.locality,
            administrativeArea: placemark.administrativeArea,
            subAdministrativeArea: placemark.subAdministrativeArea,
            postalCode: placemark.postalCode))
    }
}
