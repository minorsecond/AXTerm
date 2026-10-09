import Combine
import Foundation

/// The APRS ping and its coverage evidence, wired to an engine the same way
/// in both apps.
///
/// The map shows Ping only when the app hands it a query handler. The Mac
/// built one inline; the iPhone app never did, so on the APRS drive
/// (2026-10-09) there was no way to ping A (705) from the phone.
@MainActor
enum APRSPingWiring {

    /// Points the ping tracker and the coverage store at the engine's
    /// traffic. Keep the returned subscription for as long as they should
    /// follow it: it reseeds coverage as history loads after launch.
    static func attach(pings: APRSPingTracker, coverage: CoverageEvidenceStore,
                       to engine: PacketEngine, myCallsign: String) -> AnyCancellable {
        // Our own frames come back off the air when a digipeater repeats
        // them. Matched on the license rather than the SSID: the digipeater
        // repeats whichever of our addresses transmitted.
        let license = myCallsign.uppercased().split(separator: "-").first.map(String.init) ?? ""
        let isOurs: (String) -> Bool = { call in
            call.uppercased().split(separator: "-").first.map(String.init) == license
        }
        // A station that merely transmits after a ping has proved nothing
        // unless the timing is improbable for it; see `APRSPingTracker`.
        pings.beaconInterval = { [weak engine] call in
            engine?.aprsBeaconIntervals()[call.uppercased()]
        }
        pings.isOurs = isOurs
        pings.follow(engine.packetPublisher)
        pings.startExpiry()
        engine.aprsMessaging?.onDirectedTraffic = { [weak pings] call in
            pings?.noteDirectedReply(from: call)
        }
        // Coverage is measured from frames already on disk, so the rings
        // start from the history rather than the next beacon.
        coverage.isOurs = isOurs
        coverage.seed(engine.packets)
        coverage.follow(engine.packetPublisher)
        // History is read after launch; seeding is idempotent and only
        // rescans when the run has at least doubled.
        return engine.$packets
            .receive(on: DispatchQueue.main)
            .sink { [weak coverage] packets in coverage?.seed(packets) }
    }

    /// Sends a directed query and starts tracking it. False when no radio
    /// could carry it, and then nothing is tracked.
    ///
    /// Reach is the operator's, not a default: a direct query with no path
    /// answers "can you hear me" and nothing else, while the radio's own APRS
    /// path reaches stations a digipeater hop away but proves only
    /// reachability.
    @discardableResult
    static func sendQuery(_ ask: APRSStationQuery, coordinator: SessionCoordinator,
                          pings: APRSPingTracker) -> Bool {
        let path = ask.reach == .direct
            ? []
            : coordinator.aprsPath(forRadio: nil, addressee: ask.callsign)
        let sent = coordinator.sendAPRS(APRSOutbound(
            info: APRSMessage.directedQueryInfo(to: ask.callsign, query: ask.token),
            addressee: ask.callsign,
            path: path,
            radioID: nil))
        if sent { pings.record(ping: ask.callsign, query: ask.token, reach: ask.reach) }
        return sent
    }
}
