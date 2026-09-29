import Foundation

/// A position, with what it describes and how far wrong it can be.
///
/// Everything geometric in this app starts here, and the sources are not
/// remotely equal. Carrying the source alongside the coordinate is what lets
/// a page say "grid centre, ±4.3 km" instead of implying a survey, and what
/// lets a terrain profile decline to answer when the origin is more uncertain
/// than the path is long.
nonisolated struct StationPosition: Equatable, Sendable {

    var point: GreatCircle.Point
    var source: PositionQuality.Source
    /// Reasons this is worse than its source suggests: a post office box, or
    /// a coordinate several stations share.
    var doubts: [PositionQuality.Doubt]

    init(point: GreatCircle.Point, source: PositionQuality.Source,
         doubts: [PositionQuality.Doubt] = []) {
        self.point = point
        self.source = source
        self.doubts = doubts
    }

    /// How far the antenna might be from this coordinate.
    ///
    /// A doubt does not make the source's figure wrong so much as
    /// meaningless, so it raises the number to something that stops a page
    /// quoting metres about a post office.
    var accuracyMetres: Double {
        doubts.isEmpty ? source.accuracyMetres : max(source.accuracyMetres, 5_000)
    }

    /// The line under a callsign on the terrain card, and anywhere else a
    /// position is being relied on.
    var summary: String {
        let metres = accuracyMetres
        let distance = metres >= 1_000
            ? String(format: "%.1f km", metres / 1_000)
            : String(format: "%.0f m", metres)
        return "\(source.label) \u{00B1}\(distance)"
    }

    /// Whether this is good enough to say anything about a path of this
    /// length.
    ///
    /// A 6 km path from a grid centre good to 4.3 km is not a path, it is a
    /// guess with a chart attached. The threshold is half: beyond that the
    /// error is a large enough fraction that the terrain under it is not the
    /// terrain being flown over.
    func isUsable(forPathOf metres: Double) -> Bool {
        guard metres > 0 else { return false }
        return accuracyMetres <= metres / 2
    }
}

/// Choosing the best position available for a station.
nonisolated enum StationPositionResolver {

    /// One candidate from each source that has something to offer.
    struct Candidates: Sendable {
        var surveyed: GreatCircle.Point?
        var deviceGPS: GreatCircle.Point?
        var geocodedAddress: GreatCircle.Point?
        var announcedLocator: GreatCircle.Point?
        var licenceAddress: GreatCircle.Point?
        var gridSquare: GreatCircle.Point?
        /// The licence street line, for spotting a mailbox.
        var licenceStreet: String?
        /// How many other stations share the licence coordinate.
        var sharedWith: Int = 0

        init() {}
    }

    /// The best available, with its doubts attached.
    ///
    /// "Best" is by accuracy, and the ordering is the type's own, so adding a
    /// source later cannot quietly land in the wrong place.
    static func resolve(_ candidates: Candidates) -> StationPosition? {
        var found: [(PositionQuality.Source, GreatCircle.Point)] = []
        if let point = candidates.surveyed { found.append((.surveyed, point)) }
        if let point = candidates.deviceGPS { found.append((.deviceGPS, point)) }
        if let point = candidates.geocodedAddress { found.append((.geocodedAddress, point)) }
        if let point = candidates.licenceAddress { found.append((.licenceAddress, point)) }
        if let point = candidates.announcedLocator { found.append((.announcedLocator, point)) }
        if let point = candidates.gridSquare { found.append((.gridSquare, point)) }

        guard let best = found.min(by: { $0.0 < $1.0 }) else { return nil }

        // Doubts belong to the licence coordinate. A surveyed position is not
        // a post office because the licence happens to be one.
        var doubts: [PositionQuality.Doubt] = []
        if best.0 == .licenceAddress {
            if PositionQuality.isMailbox(candidates.licenceStreet) {
                doubts.append(.postOfficeBox)
            }
            if candidates.sharedWith > 0 {
                doubts.append(.sharedWithOthers(count: candidates.sharedWith))
            }
        }
        return StationPosition(point: best.1, source: best.0, doubts: doubts)
    }
}

// MARK: - This station

extension StationPositionResolver {

    /// Where *this* station is, from the three sources the operator controls.
    ///
    /// One definition, because there are now four callers — the Mac shell,
    /// the iOS shell, the settings page and the toolbar chip — and every
    /// time this ladder was written out again it was written slightly
    /// wrong. Twice in one afternoon the `.gps` check below was the thing
    /// omitted, publishing a 7 km grid square to the whole app as a
    /// twenty-metre fix.
    ///
    /// - Parameter deviceLocation: the service's `lastLocation`, passed
    ///   whole. It is *not* always a fix: `currentLocation()` falls back to
    ///   the grid square when GPS fails and stores that under the same
    ///   property, so the filtering belongs here rather than at each call
    ///   site that keeps forgetting it.
    static func ownStation(gridSquare: String,
                           manualLatitude: String,
                           manualLongitude: String,
                           usesDeviceLocation: Bool,
                           deviceLocation: StationLocation?) -> StationPosition? {
        var candidates = Candidates()
        candidates.surveyed = manualPoint(latitude: manualLatitude,
                                          longitude: manualLongitude)
        candidates.gridSquare = Maidenhead.center(of: gridSquare)
            .map(GreatCircle.Point.init)
        if usesDeviceLocation, let fix = deviceFix(deviceLocation) {
            candidates.deviceGPS = GreatCircle.Point(latitude: fix.latitude,
                                                     longitude: fix.longitude)
        }
        return resolve(candidates)
    }

    /// The device's last location, and only when it is genuinely a fix.
    static func deviceFix(_ location: StationLocation?) -> StationLocation? {
        guard location?.source == .gps else { return nil }
        return location
    }

    /// A typed coordinate, when both halves parse and are in range.
    static func manualPoint(latitude: String, longitude: String) -> GreatCircle.Point? {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lon)
        else { return nil }
        return GreatCircle.Point(latitude: lat, longitude: lon)
    }
}
