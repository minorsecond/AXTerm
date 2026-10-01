//
//  ReceiveLevelRecord.swift
//  AXTerm
//
//  What AXTerm remembers about one radio's receive level: the calibration,
//  the drift watch's recent samples, packet levels heard along the way, and
//  which digipeaters usually repeat us. Small and bounded, kept per radio in
//  the settings store's defaults, and decoded tolerantly so an older or newer
//  build's record never fails to load.
//

import Foundation

/// The reference a radio's receive level is judged against.
nonisolated struct ReceiveLevelBaseline: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        /// Digipeats of a calibration beacon.
        case beacon
        /// Packets caught by the drift watch's short samples.
        case passive
    }

    var at: Date
    /// The input gain step the levels below are for.
    var gain: Int
    /// Packet tones, peak to peak, at `gain`.
    var toneVpp: Int?
    /// The input between packets, peak to peak, at `gain`. Nil until measured
    /// at this gain without clipping (see `noiseSaturated`).
    var noiseVpp: Int?
    /// The noise filled the range at `gain`, so it can show the audio getting
    /// quieter but not louder.
    var noiseSaturated: Bool = false
    var source: Source = .beacon
    /// How many packets the tone level came from.
    var packets: Int = 0

    init(at: Date, gain: Int, toneVpp: Int?, noiseVpp: Int?, noiseSaturated: Bool = false,
         source: Source = .beacon, packets: Int = 0) {
        self.at = at
        self.gain = gain
        self.toneVpp = toneVpp
        self.noiseVpp = noiseVpp
        self.noiseSaturated = noiseSaturated
        self.source = source
        self.packets = packets
    }

    private enum CodingKeys: String, CodingKey {
        case at, gain, toneVpp, noiseVpp, noiseSaturated, source, packets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
        gain = try c.decodeIfPresent(Int.self, forKey: .gain) ?? 0
        toneVpp = try? c.decodeIfPresent(Int.self, forKey: .toneVpp)
        noiseVpp = try? c.decodeIfPresent(Int.self, forKey: .noiseVpp)
        noiseSaturated = (try? c.decodeIfPresent(Bool.self, forKey: .noiseSaturated)) ?? false
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .beacon
        packets = (try? c.decodeIfPresent(Int.self, forKey: .packets)) ?? 0
    }
}

/// One drift-watch sample, reduced to what the rules use.
nonisolated struct ReceiveLevelObservation: Codable, Equatable, Sendable {
    var at: Date
    var gain: Int
    /// Median peak-to-peak between packets, or nil if every report clipped.
    var noiseVpp: Int?
    /// Share of reports that touched an end of the range.
    var clippedShare: Double
    /// Packets seen in the sample: their tone levels.
    var toneVpps: [Int] = []
    /// Whether any of those packets clipped.
    var tonesClipped: Bool = false

    init(at: Date, gain: Int, noiseVpp: Int?, clippedShare: Double, toneVpps: [Int] = [],
         tonesClipped: Bool = false) {
        self.at = at
        self.gain = gain
        self.noiseVpp = noiseVpp
        self.clippedShare = clippedShare
        self.toneVpps = toneVpps
        self.tonesClipped = tonesClipped
    }

    private enum CodingKeys: String, CodingKey {
        case at, gain, noiseVpp, clippedShare, toneVpps, tonesClipped
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
        gain = try c.decodeIfPresent(Int.self, forKey: .gain) ?? 0
        noiseVpp = try? c.decodeIfPresent(Int.self, forKey: .noiseVpp)
        clippedShare = (try? c.decodeIfPresent(Double.self, forKey: .clippedShare)) ?? 0
        toneVpps = (try? c.decodeIfPresent([Int].self, forKey: .toneVpps)) ?? []
        tonesClipped = (try? c.decodeIfPresent(Bool.self, forKey: .tonesClipped)) ?? false
    }

    /// Whether the noise reading fills the range and so can't show the
    /// audio getting any louder.
    var noiseSaturated: Bool {
        guard let noiseVpp else { return true }
        return clippedShare > ReceiveLevelDrift.clipShare
            || Double(noiseVpp) >= ReceiveLevelDrift.saturatedFraction * Double(TNC4LevelSample.fullScale)
    }
}

/// One packet's tone level, from any recording.
nonisolated struct PacketLevelObservation: Codable, Equatable, Sendable {
    var at: Date
    var gain: Int
    var toneVpp: Int
    var clipped: Bool

    init(at: Date, gain: Int, toneVpp: Int, clipped: Bool) {
        self.at = at
        self.gain = gain
        self.toneVpp = toneVpp
        self.clipped = clipped
    }

    private enum CodingKeys: String, CodingKey { case at, gain, toneVpp, clipped }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
        gain = try c.decodeIfPresent(Int.self, forKey: .gain) ?? 0
        toneVpp = try c.decodeIfPresent(Int.self, forKey: .toneVpp) ?? 0
        clipped = (try? c.decodeIfPresent(Bool.self, forKey: .clipped)) ?? false
    }
}

/// Everything kept for one radio.
nonisolated struct ReceiveLevelRecord: Codable, Equatable, Sendable {
    var baseline: ReceiveLevelBaseline?
    /// Oldest first, at most `maxObservations`.
    var observations: [ReceiveLevelObservation] = []
    /// Oldest first, at most `maxPacketLevels`.
    var packetLevels: [PacketLevelObservation] = []
    var lastCalibrationBeaconAt: Date?
    var digipeats = DigipeatExpectation()
    /// Take a short level sample every half hour while connected.
    var watchEnabled = true
    /// The operator said not now to tuning this radio.
    var tuningSuggestionDismissed = false

    /// Six hours of half-hourly samples.
    static let maxObservations = 12
    /// Enough packets for a passive recommendation on a quiet channel.
    static let maxPacketLevels = 24

    init() {}

    private enum CodingKeys: String, CodingKey {
        case baseline, observations, packetLevels, lastCalibrationBeaconAt, digipeats, watchEnabled
        case tuningSuggestionDismissed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseline = try? c.decodeIfPresent(ReceiveLevelBaseline.self, forKey: .baseline)
        observations = (try? c.decodeIfPresent([ReceiveLevelObservation].self, forKey: .observations)) ?? []
        packetLevels = (try? c.decodeIfPresent([PacketLevelObservation].self, forKey: .packetLevels)) ?? []
        lastCalibrationBeaconAt = try? c.decodeIfPresent(Date.self, forKey: .lastCalibrationBeaconAt)
        digipeats = (try? c.decodeIfPresent(DigipeatExpectation.self, forKey: .digipeats)) ?? DigipeatExpectation()
        watchEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .watchEnabled)) ?? true
        tuningSuggestionDismissed = (try? c.decodeIfPresent(Bool.self, forKey: .tuningSuggestionDismissed)) ?? false
    }

    mutating func add(_ observation: ReceiveLevelObservation) {
        observations.append(observation)
        if observations.count > Self.maxObservations {
            observations.removeFirst(observations.count - Self.maxObservations)
        }
    }

    mutating func add(_ levels: [PacketLevelObservation]) {
        packetLevels.append(contentsOf: levels)
        if packetLevels.count > Self.maxPacketLevels {
            packetLevels.removeFirst(packetLevels.count - Self.maxPacketLevels)
        }
    }

    /// Observations that count against the current baseline: taken after it.
    var observationsSinceBaseline: [ReceiveLevelObservation] {
        guard let baseline else { return observations }
        return observations.filter { $0.at > baseline.at }
    }
}

/// Where records live: one JSON blob per radio in the settings store's
/// defaults, which the tests replace with a scratch suite.
nonisolated struct ReceiveLevelStore {
    let defaults: UserDefaults
    static let keyPrefix = "receiveLevel.v1."

    func load(_ radio: RadioID) -> ReceiveLevelRecord {
        guard let data = defaults.data(forKey: Self.keyPrefix + radio.rawValue),
              let record = try? JSONDecoder().decode(ReceiveLevelRecord.self, from: data) else {
            return ReceiveLevelRecord()
        }
        return record
    }

    func save(_ record: ReceiveLevelRecord, for radio: RadioID) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.keyPrefix + radio.rawValue)
    }
}

/// The APRS etiquette rule for calibration: one beacon per calibration, and
/// no more than one calibration beacon per ten minutes on a radio.
///
/// Ten minutes is the usual fixed-station beacon interval and the shortest
/// the APRS community treats as polite for a station that isn't moving. A
/// calibration beacon on top of the regular ones should never make this
/// station look chattier than that.
nonisolated enum CalibrationBeaconLimit {
    static let minimumInterval: TimeInterval = 10 * 60

    /// When the next calibration beacon may go out, or nil if it may go now.
    static func nextAllowed(after last: Date?, now: Date) -> Date? {
        guard let last else { return nil }
        let next = last.addingTimeInterval(minimumInterval)
        return next > now ? next : nil
    }
}
