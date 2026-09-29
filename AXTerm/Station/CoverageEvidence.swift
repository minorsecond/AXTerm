import Foundation

/// Who has demonstrably decoded us, and who we have demonstrably decoded,
/// per radio, from the frames themselves.
///
/// Coverage has two directions and they are not the same distance. A hilltop
/// digipeater is heard from far outside the range of a home station's own
/// transmitter, so "how far I can hear" and "how far I can be heard" routinely
/// differ by a factor of two. Reporting either one as "coverage" is half an
/// answer, and reporting the larger of them is the wrong half.
///
/// Both are measurements rather than a model:
///
/// - **Transmit.** A digipeater that put one of our own frames back on the air
///   decoded that frame. Nothing weaker counts; a station that merely
///   transmitted after we did has proved nothing.
/// - **Receive.** A frame of theirs that reached us with no digipeater having
///   repeated it came over the air from their transmitter to our receiver.
///   A digipeated frame proves the digipeater reached us and says nothing
///   about the originator, so it is not counted.
///
/// Kept per radio because two radios on two bands hear different worlds, and
/// pooling them would report one radio's reach on the other's map.
nonisolated struct CoverageEvidence: Equatable, Sendable {

    /// Digipeaters that repeated one of our own frames, and when last.
    private(set) var repeatedUs: [RadioID: [String: Date]] = [:]
    /// Stations we decoded with nothing between us, and when last.
    private(set) var heardDirect: [RadioID: [String: Date]] = [:]
    /// For each digipeater, which hop positions it has been seen repeating one
    /// of our frames at, counting only the hops that actually repeated.
    /// Position 0 means it took the frame straight off our transmitter, which
    /// is the difference between a digipeater we need a second hop to reach
    /// and one that hears us anyway.
    private(set) var repeatHops: [RadioID: [String: Set<Int>]] = [:]
    /// How many of our own frames have been heard back, which is the sample
    /// size everything drawn from `repeatHops` rests on.
    private(set) var ownFramesHeardBack: [RadioID: Int] = [:]

    init() {}

    /// Folds one received frame in.
    ///
    /// - Parameter isOurs: whether the sender is one of this station's own
    ///   addresses. Matched on the licence rather than the SSID by the
    ///   caller: a digipeater repeats whichever of our addresses transmitted.
    @discardableResult
    mutating func absorb(_ packet: Packet, isOurs: Bool) -> Bool {
        // Only what we actually received. Our own transmissions are logged
        // too, and counting the moment we keyed up as evidence that someone
        // heard it is the overclaiming this whole file exists to avoid.
        guard packet.direction == .rx else { return false }
        let radio = packet.radioID ?? .primary
        let at = packet.timestamp

        if isOurs {
            // Our frame, back off the air. Every hop marked repeated on it
            // decoded us.
            var changed = false
            // Position among the hops that repeated, not among all of them: a
            // requested-but-unused WIDE sitting in the middle of the path
            // must not push the next real digipeater down a place.
            var position = 0
            if packet.via.contains(where: \.repeated) {
                ownFramesHeardBack[radio, default: 0] += 1
                changed = true
            }
            for hop in packet.via where hop.repeated {
                let call = hop.display.uppercased()
                guard !call.isEmpty else { continue }
                changed = record(call, at: at, radio: radio, in: &repeatedUs) || changed
                var forRadio = repeatHops[radio] ?? [:]
                if forRadio[call, default: []].insert(position).inserted {
                    changed = true
                    repeatHops[radio] = forRadio
                }
                position += 1
            }
            return changed
        }

        // Somebody else's frame. Direct only: if any hop repeated it, what
        // reached us was the digipeater's transmitter, not theirs.
        guard !packet.via.contains(where: \.repeated),
              let from = packet.from?.display.uppercased(), !from.isEmpty else { return false }
        return record(from, at: at, radio: radio, in: &heardDirect)
    }

    /// Returns whether this was news. A busy channel repeats the same
    /// stations all day, and republishing an unchanged picture per frame
    /// would redraw the map for nothing.
    private func record(_ call: String, at: Date, radio: RadioID,
                        in table: inout [RadioID: [String: Date]]) -> Bool {
        var forRadio = table[radio] ?? [:]
        guard at > forRadio[call] ?? .distantPast else { return false }
        forRadio[call] = at
        table[radio] = forRadio
        return true
    }

    /// Everything one radio heard repeat us.
    func repeatedUs(on radios: Set<RadioID>) -> [String: Date] {
        merged(repeatedUs, on: radios)
    }

    /// Everything one radio heard direct.
    func heardDirect(on radios: Set<RadioID>) -> [String: Date] {
        merged(heardDirect, on: radios)
    }

    /// How many of our own frames came back on these radios.
    func ownFramesHeardBack(on radios: Set<RadioID>) -> Int {
        radios.reduce(0) { $0 + (ownFramesHeardBack[$1] ?? 0) }
    }

    /// Which hop positions each digipeater has repeated us at.
    func repeatHops(on radios: Set<RadioID>) -> [String: Set<Int>] {
        var result: [String: Set<Int>] = [:]
        for radio in radios.sorted(by: RadioID.deterministicOrder) {
            for (call, hops) in repeatHops[radio] ?? [:] {
                result[call, default: []].formUnion(hops)
            }
        }
        return result
    }

    /// Radios on the same frequency hear the same air, so their evidence
    /// rolls up; radios on different bands never do.
    private func merged(_ table: [RadioID: [String: Date]],
                        on radios: Set<RadioID>) -> [String: Date] {
        var result: [String: Date] = [:]
        for radio in radios.sorted(by: RadioID.deterministicOrder) {
            for (call, at) in table[radio] ?? [:] where at > result[call] ?? .distantPast {
                result[call] = at
            }
        }
        return result
    }

    /// Builds the whole picture from a run of frames — the packet history at
    /// launch, so a ring does not start empty and wait hours for the next
    /// beacon to come back.
    static func from(_ packets: [Packet], isOurs: (String) -> Bool) -> CoverageEvidence {
        var evidence = CoverageEvidence()
        for packet in packets {
            let ours = packet.from.map { isOurs($0.display) } ?? false
            evidence.absorb(packet, isOurs: ours)
        }
        return evidence
    }
}
