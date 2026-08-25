import Foundation

/// Maidenhead grid-square locator utilities.
///
/// Used for the Winlink gateway-proximity lookup (the CMS API takes the
/// operator's grid square) and for showing distance/bearing to RMS
/// stations. Supports 4-, 6-, and 8-character locators.
nonisolated enum Maidenhead {

    struct Coordinate: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
    }

    /// The locator for a position, at 4, 6, or 8 characters.
    ///
    /// Pure arithmetic — no network, no services, nothing that can be
    /// unavailable. A GPS fix is therefore enough to fill in a grid
    /// square anywhere, including with every other system down, which is
    /// exactly when it matters.
    ///
    /// Six characters (a subsquare, roughly 8 × 4.6 km) is the default:
    /// it is what Winlink and the link-quality placement rules expect,
    /// and four characters carries 60 km of uncertainty.
    static func locator(latitude: Double, longitude: Double, precision: Int = 6) -> String? {
        guard [4, 6, 8].contains(precision) else { return nil }
        guard latitude >= -90, latitude <= 90, longitude >= -180, longitude <= 180 else {
            return nil
        }

        // Shift into positive space; clamp the poles and the date line so
        // the top of the range lands inside the last square rather than
        // one past it.
        let lon = min(longitude + 180, 359.999999)
        let lat = min(latitude + 90, 179.999999)

        let fieldLon = Int(lon / 20)
        let fieldLat = Int(lat / 10)
        var result = String(UnicodeScalar(UInt8(65 + fieldLon)))
        result += String(UnicodeScalar(UInt8(65 + fieldLat)))

        let lonAfterField = lon - Double(fieldLon) * 20
        let latAfterField = lat - Double(fieldLat) * 10
        let squareLon = Int(lonAfterField / 2)
        let squareLat = Int(latAfterField)
        result += "\(squareLon)\(squareLat)"
        if precision == 4 { return result }

        let lonAfterSquare = lonAfterField - Double(squareLon) * 2
        let latAfterSquare = latAfterField - Double(squareLat)
        let subLon = min(23, Int(lonAfterSquare / (2.0 / 24)))
        let subLat = min(23, Int(latAfterSquare / (1.0 / 24)))
        result += String(UnicodeScalar(UInt8(97 + subLon)))
        result += String(UnicodeScalar(UInt8(97 + subLat)))
        if precision == 6 { return result }

        let lonAfterSub = lonAfterSquare - Double(subLon) * (2.0 / 24)
        let latAfterSub = latAfterSquare - Double(subLat) * (1.0 / 24)
        let extLon = min(9, Int(lonAfterSub / (2.0 / 240)))
        let extLat = min(9, Int(latAfterSub / (1.0 / 240)))
        result += "\(extLon)\(extLat)"
        return result
    }

    /// True when `grid` is a syntactically valid 4/6/8-character locator.
    static func isValid(_ grid: String) -> Bool {
        center(of: grid) != nil
    }

    /// The lat/lon center of a grid square, or nil if malformed.
    static func center(of grid: String) -> Coordinate? {
        let chars = Array(grid.uppercased())
        guard [4, 6, 8].contains(chars.count) else { return nil }

        func letterValue(_ c: Character, maxLetter: Character) -> Int? {
            guard let scalar = c.unicodeScalars.first?.value,
                  let a = Character("A").unicodeScalars.first?.value,
                  let max = maxLetter.unicodeScalars.first?.value,
                  scalar >= a, scalar <= max
            else { return nil }
            return Int(scalar - a)
        }
        func digitValue(_ c: Character) -> Int? {
            c.wholeNumberValue.flatMap { (0...9).contains($0) ? $0 : nil }
        }

        guard let fieldLon = letterValue(chars[0], maxLetter: "R"),
              let fieldLat = letterValue(chars[1], maxLetter: "R"),
              let squareLon = digitValue(chars[2]),
              let squareLat = digitValue(chars[3])
        else { return nil }

        var lon = Double(fieldLon) * 20.0 - 180.0 + Double(squareLon) * 2.0
        var lat = Double(fieldLat) * 10.0 - 90.0 + Double(squareLat) * 1.0
        var lonSpan = 2.0
        var latSpan = 1.0

        if chars.count >= 6 {
            guard let subLon = letterValue(chars[4], maxLetter: "X"),
                  let subLat = letterValue(chars[5], maxLetter: "X")
            else { return nil }
            lonSpan = 2.0 / 24.0
            latSpan = 1.0 / 24.0
            lon += Double(subLon) * lonSpan
            lat += Double(subLat) * latSpan
        }

        if chars.count == 8 {
            guard let extLon = digitValue(chars[6]),
                  let extLat = digitValue(chars[7])
            else { return nil }
            let parentLonSpan = lonSpan
            let parentLatSpan = latSpan
            lonSpan = parentLonSpan / 10.0
            latSpan = parentLatSpan / 10.0
            lon += Double(extLon) * lonSpan
            lat += Double(extLat) * latSpan
        }

        return Coordinate(latitude: lat + latSpan / 2.0, longitude: lon + lonSpan / 2.0)
    }

    /// Encodes a coordinate as a Maidenhead locator (4, 6, or 8 chars).
    static func gridSquare(latitude: Double, longitude: Double, length: Int = 6) -> String? {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude),
              [4, 6, 8].contains(length)
        else { return nil }

        // Clamp the north/east edges into the last cell.
        let lon = min(longitude, 179.999_999) + 180.0
        let lat = min(latitude, 89.999_999) + 90.0

        let fieldLon = Int(lon / 20.0)
        let fieldLat = Int(lat / 10.0)
        let squareLon = Int((lon - Double(fieldLon) * 20.0) / 2.0)
        let squareLat = Int(lat - Double(fieldLat) * 10.0)

        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWX")
        var grid = ""
        grid.append(letters[fieldLon])
        grid.append(letters[fieldLat])
        grid.append(String(squareLon))
        grid.append(String(squareLat))
        if length == 4 { return grid }

        let subLonUnits = (lon - Double(fieldLon) * 20.0 - Double(squareLon) * 2.0) * 12.0
        let subLatUnits = (lat - Double(fieldLat) * 10.0 - Double(squareLat)) * 24.0
        let subLon = min(Int(subLonUnits), 23)
        let subLat = min(Int(subLatUnits), 23)
        grid.append(Character(letters[subLon].lowercased()))
        grid.append(Character(letters[subLat].lowercased()))
        if length == 6 { return grid }

        let extLon = min(Int((subLonUnits - Double(subLon)) * 10.0), 9)
        let extLat = min(Int((subLatUnits - Double(subLat)) * 10.0), 9)
        grid.append(String(extLon))
        grid.append(String(extLat))
        return grid
    }

    /// Great-circle distance in kilometers between two grid squares.
    static func distanceKm(from: String, to: String) -> Double? {
        guard let a = center(of: from), let b = center(of: to) else { return nil }
        return haversineKm(a, b)
    }

    /// Initial bearing in degrees (0–360) from one grid square to another.
    static func bearingDegrees(from: String, to: String) -> Double? {
        guard let a = center(of: from), let b = center(of: to) else { return nil }
        return bearingDegrees(from: a, to: b)
    }

    /// Initial bearing in degrees (0–360) between two coordinates.
    static func bearingDegrees(from a: Coordinate, to b: Coordinate) -> Double? {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    static func haversineKm(_ a: Coordinate, _ b: Coordinate) -> Double {
        let earthRadiusKm = 6371.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusKm * asin(min(1, sqrt(h)))
    }
}
