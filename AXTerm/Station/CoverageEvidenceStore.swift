import Combine
import Foundation

/// Keeps `CoverageEvidence` current, seeded from history and topped up live.
///
/// Seeding is the point. The evidence this collects is sparse — on a quiet
/// channel one of our own beacons finds its way back through a digipeater
/// every couple of hours — so a store that started empty at launch left the
/// coverage ring blank for most of a session while the proof sat in the
/// packet history all along (2026-09-17).
@MainActor
final class CoverageEvidenceStore: ObservableObject {

    @Published private(set) var evidence = CoverageEvidence()

    /// Whether a callsign is one this station transmits as. Matched on the
    /// licence rather than the SSID: a digipeater repeats whichever of our
    /// addresses transmitted.
    var isOurs: ((String) -> Bool)?

    private var cancellable: AnyCancellable?
    /// How many frames the last scan covered, so a history that lands after
    /// the first seed is not ignored and ordinary live growth does not
    /// trigger a rescan per frame.
    private var seededCount = 0

    /// Folds stored history in.
    ///
    /// Merging rather than replacing, so calling it again is harmless: a
    /// sighting is only recorded when it is newer than the one held. It scans
    /// when the run is the first, or when it has at least doubled — which
    /// catches persisted history arriving after a live frame beat it to the
    /// buffer, and nothing else.
    func seed(_ packets: [Packet]) {
        guard !packets.isEmpty,
              seededCount == 0 || packets.count > seededCount * 2 else { return }
        seededCount = packets.count
        var next = evidence
        for packet in packets {
            let ours = packet.from.map { isOurs?($0.display) ?? false } ?? false
            next.absorb(packet, isOurs: ours)
        }
        guard next != evidence else { return }
        evidence = next
    }

    /// Follows the live channel. Hopped to main for the same reason
    /// `APRSPingTracker` does: frames arrive on whatever thread decoded them
    /// and this publishes to SwiftUI.
    func follow(_ packets: AnyPublisher<Packet, Never>) {
        cancellable = packets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] packet in
                guard let self else { return }
                let ours = packet.from.map { self.isOurs?($0.display) ?? false } ?? false
                var next = self.evidence
                // Published only when the frame was news, so a channel
                // repeating the same stations does not redraw the map.
                guard next.absorb(packet, isOurs: ours) else { return }
                self.evidence = next
            }
    }
}
