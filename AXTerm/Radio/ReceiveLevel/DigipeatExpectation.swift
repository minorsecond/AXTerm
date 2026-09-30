//
//  DigipeatExpectation.swift
//  AXTerm
//
//  Which digipeaters usually repeat this radio's APRS frames, and whether
//  they have stopped being heard doing it.
//

import Foundation

/// Learns who repeats us, and notices when several frames in a row come back
/// from nobody.
///
/// On an APRS channel our own frames are the one kind of traffic whose
/// arrival we can predict: a digipeater that hears us repeats the frame
/// within a few seconds. If WA0DE-3 repeated nine of our last ten beacons and
/// the last three came back from no one, the likeliest change is at our end:
/// the radio's volume, squelch or antenna. That needs no second receiver to
/// notice. It can't tell our receiver failing from our transmitter failing,
/// and the message says so.
///
/// Counts any UI frame this radio sends through a digipeater path (beacons,
/// messages, objects): each is a chance to be repeated. The echo is the last
/// hop marked used on the copy we hear, which is the station whose
/// transmission reached us.
nonisolated struct DigipeatExpectation: Codable, Equatable, Sendable {

    struct Sent: Codable, Equatable, Sendable {
        var at: Date
        /// Who repeated it, sorted.
        var echoedBy: [String]
    }

    /// Oldest first, at most `history`.
    private(set) var sent: [Sent] = []

    /// Twenty frames: at a ten-minute beacon, a little over three hours.
    static let history = 20
    /// Copies heard up to 30 s after sending count. A second hop can take
    /// ten seconds or more behind a busy first one.
    static let echoWindow: TimeInterval = 30
    /// Three frames in a row with no echo. One or two lost to a collision is
    /// ordinary on a busy channel; three in a row, from digipeaters that
    /// repeat nearly everything, is not.
    static let missesBeforeWarning = 3
    /// At least five earlier frames to learn from before judging.
    static let learnFrom = 5
    /// A digipeater that repeated at least 60% of the earlier frames is one
    /// we expect to hear.
    static let usualShare = 0.6

    init() {}

    private enum CodingKeys: String, CodingKey { case sent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sent = (try? c.decodeIfPresent([Sent].self, forKey: .sent)) ?? []
    }

    mutating func noteSent(at date: Date) {
        sent.append(Sent(at: date, echoedBy: []))
        if sent.count > Self.history { sent.removeFirst(sent.count - Self.history) }
    }

    /// A copy of one of our frames came back through `digipeater` at `date`.
    /// Credited to the latest frame sent within the echo window before it.
    @discardableResult
    mutating func noteEcho(from digipeater: String, at date: Date) -> Bool {
        let call = digipeater.uppercased()
        guard !call.isEmpty,
              let index = sent.lastIndex(where: { $0.at <= date && date.timeIntervalSince($0.at) <= Self.echoWindow })
        else { return false }
        guard !sent[index].echoedBy.contains(call) else { return false }
        sent[index].echoedBy.append(call)
        sent[index].echoedBy.sort()
        return true
    }

    struct Finding: Equatable, Sendable {
        /// Digipeaters that usually repeat us, with how many of the earlier
        /// frames each repeated.
        let usual: [(call: String, repeated: Int)]
        let earlierFrames: Int
        /// Frames in a row that came back from nobody.
        let misses: Int
        let lastEchoAt: Date?

        static func == (a: Finding, b: Finding) -> Bool {
            a.usual.map(\.call) == b.usual.map(\.call) && a.usual.map(\.repeated) == b.usual.map(\.repeated)
                && a.earlierFrames == b.earlierFrames && a.misses == b.misses && a.lastEchoAt == b.lastEchoAt
        }
    }

    /// The finding, or nil when the recent frames came back as usual or there
    /// isn't enough history to say.
    func assess(now: Date) -> Finding? {
        // Only frames whose echo window has closed.
        let settled = sent.filter { now.timeIntervalSince($0.at) > Self.echoWindow }
        var misses = 0
        for frame in settled.reversed() {
            guard frame.echoedBy.isEmpty else { break }
            misses += 1
        }
        guard misses >= Self.missesBeforeWarning else { return nil }
        let earlier = Array(settled.dropLast(misses))
        guard earlier.count >= Self.learnFrom else { return nil }
        var counts: [String: Int] = [:]
        for frame in earlier { for call in frame.echoedBy { counts[call, default: 0] += 1 } }
        let usual = counts
            .filter { Double($0.value) >= Self.usualShare * Double(earlier.count) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (call: $0.key, repeated: $0.value) }
        guard !usual.isEmpty else { return nil }
        let lastEcho = earlier.last { !$0.echoedBy.isEmpty }?.at
        return Finding(usual: usual, earlierFrames: earlier.count, misses: misses, lastEchoAt: lastEcho)
    }
}
