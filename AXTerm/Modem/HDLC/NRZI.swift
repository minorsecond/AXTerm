import Foundation

/// NRZI as AX.25 uses it: a data 0 is a change of level, a data 1 is no
/// change. Because only *changes* carry information, the decoder does not
/// care which tone is "high" — an inverted audio path, swapped tones or a
/// radio with the opposite deviation sense all decode the same.
nonisolated struct NRZIDecoder: Equatable, Sendable {
    private var previous: Bool?

    init() {}

    /// The data bit implied by the newest level. The very first level has
    /// nothing to compare with and is reported as a 1, which the flag hunt
    /// absorbs.
    mutating func decode(level: Bool) -> Bool {
        defer { previous = level }
        guard let previous else { return true }
        return previous == level
    }

    mutating func reset() { previous = nil }
}

nonisolated struct NRZIEncoder: Equatable, Sendable {
    /// The line level after the last bit.
    private(set) var level = false

    init(initialLevel: Bool = false) { level = initialLevel }

    /// The level to transmit for `bit`: toggled for a 0, held for a 1.
    mutating func encode(bit: Bool) -> Bool {
        if !bit { level.toggle() }
        return level
    }

    mutating func reset() { level = false }
}
