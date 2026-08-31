import Foundation

/// Fetches and caches the day's space weather.
///
/// Captured when a session runs rather than when someone opens the history,
/// because the point is to still have it later — and the day an operator
/// most wants to know what the ionosphere was doing is the day there is no
/// internet to ask. A day already on disk is never re-fetched.
///
/// Every failure here is silent by design. No network is the normal case in
/// the field, and a missing reading is simply a day with no numbers; it must
/// never interrupt or fail an exchange.
nonisolated struct SolarConditionsService: Sendable {

    let store: WinlinkStore
    var session: URLSession = .shared

    /// Midnight UTC of a day — the resolution the indices actually have.
    static func day(containing date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.startOfDay(for: date)
    }

    /// Cached first, network only if we have nothing.
    func conditions(for date: Date) async -> SolarConditions? {
        let day = Self.day(containing: date)
        if let stored = try? store.solarConditions(forDay: day) { return stored }
        guard let fetched = await fetch(day: day) else { return nil }
        try? store.saveSolarConditions(fetched)
        return fetched
    }

    /// Record the day's conditions if they are not already known.
    func captureIfNeeded(for date: Date) async {
        _ = await conditions(for: date)
    }

    private func fetch(day: Date) async -> SolarConditions? {
        async let flux = value(from: SolarConditionsFeed.fluxURL) { data in
            // The last reading on or before this day: the flux is published
            // daily and a session at 08:00 is described by that day's number.
            try SolarConditionsFeed.parseFlux(data)
                .filter { $0.time <= day.addingTimeInterval(86_400) }
                .max(by: { $0.time < $1.time })?.flux
        }
        async let kIndex = value(from: SolarConditionsFeed.planetaryKURL) { data in
            // The day's *maximum* Kp, not the latest: a storm at 03:00 is
            // what explains a session at 04:00, and an average would hide it.
            try SolarConditionsFeed.parsePlanetaryK(data)
                .filter { Self.day(containing: $0.time) == day }
                .map(\.kIndex).max()
        }

        let (solarFlux, k) = await (flux, kIndex)
        // Nothing at all is not a reading — storing an empty row would make
        // the day look answered when it is not.
        guard solarFlux != nil || k != nil else { return nil }
        return SolarConditions(
            day: day,
            solarFlux: solarFlux,
            kIndex: k,
            source: "NOAA SWPC",
            fetchedAt: Date())
    }

    private func value(
        from url: URL,
        parse: @Sendable (Data) throws -> Double?
    ) async -> Double? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return try? parse(data)
    }
}
