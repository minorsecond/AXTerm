import Foundation

/// How busy the channel actually is, measured rather than felt.
///
/// "The channel is busy" is the reason given for most APRS advice and almost
/// nobody measures it. Three numbers do, and they answer different questions:
///
/// - **Frames a minute** is how it feels. It is also the least useful, because
///   a minute of short Mic-E beacons and a minute of long weather bulletins
///   read the same.
/// - **Occupancy** is what matters for collisions: the share of the window
///   actually filled with data. Two stations that transmit at once on a shared
///   channel both lose, and the chance of that rises steeply with occupancy
///   rather than with frame count.
/// - **Duplicate share** is how much of the traffic is the network repeating
///   itself. A channel that is 30% duplicates is carrying a third less unique
///   information than its frame count suggests, and is the clearest sign that
///   the paths in use locally are longer than the network needs.
nonisolated struct APRSChannelLoad: Equatable, Sendable {

    /// How long a window this covers.
    let window: TimeInterval
    let frames: Int
    let framesPerMinute: Double
    /// Share of the window filled with data, 0…1.
    ///
    /// Data only. Every transmission also carries a key-up delay before the
    /// first flag, which is the *transmitting* station's setting and cannot be
    /// known from a received frame — typically 200–500 ms, which on short
    /// beacons is comparable to the data itself. So the real figure is higher
    /// than this, and by an unknown amount. Understating it is the safe
    /// direction for a number used to argue for shorter paths.
    let occupancy: Double
    /// Share of frames that were another copy of one already heard.
    let duplicateShare: Double
    /// What the arithmetic assumed, so the figure can be checked.
    let baud: Int

    /// Busy enough that extra copies cost something.
    ///
    /// A judgement, not physics. On a shared channel with no coordination,
    /// throughput peaks somewhere near a fifth of capacity and collisions
    /// climb steeply before that; a tenth is where the cost of an avoidable
    /// extra transmission stops being theoretical.
    static let busyOccupancy = 0.10

    /// Enough of the channel is the network echoing itself to be worth saying.
    static let echoHeavyDuplicateShare = 0.35

    /// Typical key-up before a transmitter's first flag.
    ///
    /// The *sending* station's setting, so it cannot be read off a received
    /// frame; 300 ms is the common default and the figure most trackers ship.
    /// It is not a detail: on the short beacons that make up most of an APRS
    /// channel it is comparable to the data itself, so occupancy that ignores
    /// it is wrong by nearly half.
    static let assumedKeyUp: TimeInterval = 0.3

    /// Occupancy with a typical key-up added for each frame.
    ///
    /// The figure to judge congestion by. `occupancy` is what was measured;
    /// this is what was measured plus the part that is known to be there and
    /// cannot be observed, and the assumption is named so it can be argued
    /// with.
    var occupancyIncludingKeyUp: Double {
        guard window > 0 else { return 0 }
        return min(1, occupancy + Double(frames) * Self.assumedKeyUp / window)
    }

    var isBusy: Bool { occupancyIncludingKeyUp >= Self.busyOccupancy }
    var isEchoHeavy: Bool { duplicateShare >= Self.echoHeavyDuplicateShare }

    var summary: String {
        let percent = String(format: "%.1f%%", occupancy * 100)
        let dupes = String(format: "%.0f%%", duplicateShare * 100)
        let total = String(format: "%.1f%%", occupancyIncludingKeyUp * 100)
        return "\(String(format: "%.1f", framesPerMinute)) frames a minute, "
            + "\(percent) of the air as data and about \(total) once a typical key-up "
            + "is allowed for, \(dupes) of it repeats"
    }
}

nonisolated enum APRSChannelLoadMeter {

    /// AX.25 overhead around the payload, in octets: two addresses, control,
    /// PID, frame check, and the flags that bracket it.
    private static let framingOctets = 14 + 1 + 1 + 2 + 2
    /// Bit stuffing inserts a zero after five ones, which on typical traffic
    /// adds a low single-digit percentage. Rounded up rather than modelled.
    private static let bitStuffingFactor = 1.03

    /// Airtime one frame occupied, in seconds, from its own size.
    ///
    /// Computed from the parts rather than the raw bytes so a frame read back
    /// from storage, which does not carry them, measures the same as a live
    /// one.
    static func airtime(_ packet: Packet, baud: Int) -> TimeInterval {
        guard baud > 0 else { return 0 }
        let octets = framingOctets + 7 * packet.via.count + packet.info.count
        let bits = Double(octets) * 8 * bitStuffingFactor
        return bits / Double(baud)
    }

    /// Measures the window ending at `now`.
    ///
    /// Only received frames count. Our own transmissions occupy the channel
    /// too, but a station cannot hear itself and counting what we sent against
    /// what we heard would mix a complete record with a partial one.
    static func measure(packets: [Packet],
                        window: TimeInterval = 900,
                        baud: Int = 1200,
                        now: Date = Date()) -> APRSChannelLoad {
        let cutoff = now.addingTimeInterval(-window)
        let recent = packets
            .filter { $0.direction == .rx && $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }

        guard !recent.isEmpty, window > 0 else {
            return APRSChannelLoad(window: window, frames: 0, framesPerMinute: 0,
                                   occupancy: 0, duplicateShare: 0, baud: baud)
        }

        var busySeconds: TimeInterval = 0
        var duplicates = 0
        // Same sender and same payload, heard again by a different path inside
        // the window: the network repeating itself rather than a station
        // beaconing twice. Mirrors the rule the console already applies.
        var seen: [String: [[String]]] = [:]
        for packet in recent {
            busySeconds += airtime(packet, baud: baud)
            let signature = (packet.from?.display.uppercased() ?? "?")
                + "|" + packet.info.map { String(format: "%02x", $0) }.joined()
            let path = packet.via.map { $0.display.uppercased() }
            if let paths = seen[signature] {
                if !paths.contains(path) { duplicates += 1 }
            }
            seen[signature, default: []].append(path)
        }

        return APRSChannelLoad(
            window: window,
            frames: recent.count,
            framesPerMinute: Double(recent.count) / (window / 60),
            occupancy: min(1, busySeconds / window),
            duplicateShare: Double(duplicates) / Double(recent.count),
            baud: baud)
    }
}
