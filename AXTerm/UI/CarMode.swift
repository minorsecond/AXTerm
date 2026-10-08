import Foundation

/// The map's car mode (operator, 2026-10-07): the map follows the station
/// like a navigation app and shows only what helps at a glance, with one
/// line saying when the station last beaconed and which digipeaters
/// repeated it.
nonisolated enum CarMode {
    /// Where the switch lives, read by the map and the shell's keep-awake.
    static let storageKey = "map.carMode"
    /// What the map screen draws.
    struct Chrome: Equatable {
        var rings = true
        var trails = true
        var paths = true
        var overlays = true
        var legend = true
        var banners = true
        var trafficStrip = true
        var toolbar = true

        init(carMode: Bool) {
            guard carMode else { return }
            rings = false; trails = false; paths = false; overlays = false
            legend = false; banners = false; trafficStrip = false; toolbar = false
        }
    }

    /// The digipeaters that repeated a frame of ours heard since `since`, in
    /// the order first heard. Generic path aliases (WIDE, TRACE, RELAY) name
    /// no station, so they are left out.
    static func heardBy(_ packets: [Packet], ownAddresses: Set<String>, since: Date) -> [String] {
        let aliases = ["WIDE", "TRACE", "RELAY"]
        var names: [String] = []
        for packet in packets.sorted(by: { $0.timestamp < $1.timestamp })
        where packet.timestamp >= since && ownAddresses.contains(packet.from?.display ?? "") {
            for digi in packet.via where digi.repeated {
                let call = digi.call.uppercased()
                guard !aliases.contains(where: { call.hasPrefix($0) }), !names.contains(call) else { continue }
                names.append(call)
            }
        }
        return names
    }

    /// Car mode draws stations heard in the last hour.
    static func keeps(lastHeard: Date?, now: Date) -> Bool {
        guard let lastHeard else { return false }
        return now.timeIntervalSince(lastHeard) <= 3600
    }

    static func beaconLine(lastBeacon: Date?, now: Date, heardBy: [String]) -> String {
        guard let lastBeacon else { return "No beacon yet" }
        let seconds = max(0, Int(now.timeIntervalSince(lastBeacon)))
        let age = seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
        let heard = heardBy.isEmpty ? "no digipeater heard it" : "heard by " + heardBy.joined(separator: ", ")
        return "Beaconed \(age) ago · \(heard)"
    }
}
