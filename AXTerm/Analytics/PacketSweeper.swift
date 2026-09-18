import Foundation

/// Folds the live packet window into the durable tables, off the main actor.
///
/// Both halves of this work read a few hundred packets and then open a GRDB
/// write transaction. Called inline from a SwiftUI `onReceive` they put that
/// transaction on the thread that draws the map, once every five seconds, for
/// as long as the app ran. A sample taken on a station that had been up two
/// and a half hours caught the main thread inside
/// `SQLiteStationServiceStore.record` → `Database.inTransaction`, behind a soft
/// modem already holding most of a core. Nothing was visibly wrong, which is
/// the problem with a hitch that only shows up under traffic.
///
/// An actor rather than a loose `Task.detached`: blocking the main thread used
/// to serialize these sweeps by accident. GRDB would still serialize the
/// writes on its own queue, but nothing would stop a slow sweep from being
/// lapped by the next one, and the second would then rewrite rows the first
/// was still counting. The body never suspends, so the actor runs one sweep to
/// completion before starting another, which is the ordering the old code got
/// for free.
///
/// The windows are the caller's, not this type's. The Mac reads more of the
/// buffer than the handheld does, and the path observer reads more than the
/// service harvest, because a service declaration repeats and a path may not:
/// missing one ID costs nothing, missing the only frame that ever showed a
/// route costs the route.
actor PacketSweeper {

    /// Harvests the station directory and the observed-path table from a
    /// window of live traffic.
    ///
    /// Both stores are optional for the same reason they are optional on the
    /// engine: a build with no database still runs, and a sweep with nothing
    /// to write into is a no-op rather than a precondition failure.
    /// Returns the merged live-plus-remembered path set, so the caller can
    /// hold it rather than rebuild it.
    ///
    /// `rememberedNetworkPaths` used to be a computed property on the view: a
    /// 600-packet parse and a read across the store's whole retention window,
    /// re-run every time SwiftUI evaluated anything that depended on it, which
    /// included a closure called once per station row. Days-old evidence does
    /// not change between two frames, so it is gathered here on the same
    /// five-second tick as the writes and handed back once.
    @discardableResult
    func sweep(packets: [Packet],
               localCallsign: String,
               services: StationServiceStore?,
               paths: NetworkPathStore?,
               serviceWindow: Int,
               pathWindow: Int,
               retention: TimeInterval) -> [NetworkPath] {
        if let services {
            let recent = Array(packets.suffix(serviceWindow))
            let observed = StationServiceHarvester.declarations(in: recent)
                + StationServiceHarvester.demonstratedDigipeaters(in: recent)
            try? services.record(observed)
        }
        // Only what was actually observed. Transitive paths are re-derived on
        // demand from whatever the graph holds, and storing an inference would
        // let it harden into a fact that outlives its evidence.
        let live = NetworkPathObserver.paths(in: Array(packets.suffix(pathWindow)),
                                             localCallsign: localCallsign)
        guard let paths else { return NetworkPath.merging(live) }
        try? paths.record(live, now: Date())
        let remembered = (try? paths.paths(since: Date().addingTimeInterval(-retention))) ?? []
        return NetworkPath.merging(live + remembered)
    }
}
