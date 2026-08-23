import Foundation

/// A resolved station position, usable anywhere in the app (Winlink
/// messages and forms, BBS/terminal messages, position reports).
nonisolated struct StationLocation: Equatable, Sendable {

    enum Source: String, Sendable {
        case gps = "GPS"
        case manualGrid = "Grid square"
    }

    var latitude: Double
    var longitude: Double
    var gridSquare: String
    var source: Source
    var timestamp: Date
}

/// Position text formats matching the Winlink insertion-tag conventions
/// (RMSE_FORMS/insertion_tags — same formats the standard templates use).
nonisolated enum StationLocationFormat {

    /// `39.7392 -104.9903`
    static func signedDecimal(_ location: StationLocation) -> String {
        String(format: "%.4f %.4f", location.latitude, location.longitude)
    }

    /// `39.7392N 104.9903W`
    static func decimal(_ location: StationLocation) -> String {
        String(
            format: "%.4f%@ %.4f%@",
            abs(location.latitude), location.latitude >= 0 ? "N" : "S",
            abs(location.longitude), location.longitude >= 0 ? "E" : "W")
    }

    /// `39-44.35N 104-59.42W`
    static func degreeMinute(_ location: StationLocation) -> String {
        let latDegrees = Int(abs(location.latitude))
        let latMinutes = (abs(location.latitude) - Double(latDegrees)) * 60
        let lonDegrees = Int(abs(location.longitude))
        let lonMinutes = (abs(location.longitude) - Double(lonDegrees)) * 60
        return String(
            format: "%02d-%05.2f%@ %03d-%05.2f%@",
            latDegrees, latMinutes, location.latitude >= 0 ? "N" : "S",
            lonDegrees, lonMinutes, location.longitude >= 0 ? "E" : "W")
    }

    /// One-line stamp for inserting into message bodies:
    /// `Position: 39.7392 -104.9903 (DM79lr) via GPS 2026-08-23 14:30 UTC`
    static func stamp(_ location: StationLocation) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let time = formatter.string(from: location.timestamp)
        return "Position: \(signedDecimal(location)) (\(location.gridSquare)) via \(location.source.rawValue) \(time) UTC"
    }
}
