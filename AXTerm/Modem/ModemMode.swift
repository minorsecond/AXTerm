import Foundation

/// What the built-in modem speaks.
///
/// Each mode fixes the tones, the bit rate and the sample rate the
/// demodulator runs at. Whether a mode can transmit is a fact about the
/// radio path as much as the code: the IC-705 has no 9600 data jack, so its
/// 9600 is receive-only from the 12 kHz IF output.
nonisolated enum ModemMode: String, Codable, CaseIterable, Sendable {
    /// Bell 202 — 1200/2200 Hz at 1200 bd. VHF/UHF FM packet, FM-D on the radio.
    case afsk1200
    /// 1600/1800 Hz at 300 bd — HF packet on SSB, USB-D on the radio.
    case afsk300
    /// G3RUH 9600 bd from a 12 kHz IF. Receive only.
    case g3ruh9600RxIF

    struct Parameters: Equatable, Sendable {
        let markHz: Double
        let spaceHz: Double
        let baud: Double
        /// The rate the demodulator runs at; audio is decimated to it.
        let demodSampleRate: Double
        let isTxCapable: Bool
        /// How the tone detectors smooth their power before the comparison.
        /// Declared per mode rather than derived: the two AFSK modes sit at
        /// shift/baud of 0.83 and 0.67, and any threshold separating two
        /// points that close is a coincidence dressed as a rule.
        let detectorFilter: AFSKDemodulator.DetectorFilter
    }

    var parameters: Parameters {
        switch self {
        case .afsk1200:
            // 2.5 bit periods: measured. Against a sharp lowpass it takes the
            // hardest bench condition from 26 frames of 40 to 38, is never
            // worse anywhere in the matrix, and costs no inter-symbol
            // interference even on a 200-byte frame with no noise to hide it.
            return Parameters(markHz: 1200, spaceHz: 2200, baud: 1200, demodSampleRate: 12_000,
                              isTxCapable: true, detectorFilter: .integrator(bits: 2.5))
        case .afsk300:
            // The 200 Hz beat falls below the 300 bd bit rate, so no short
            // window can separate the tones; only a sharp filter does.
            return Parameters(markHz: 1600, spaceHz: 1800, baud: 300, demodSampleRate: 12_000,
                              isTxCapable: true, detectorFilter: .sharpLowpass)
        case .g3ruh9600RxIF:
            return Parameters(markHz: 0, spaceHz: 0, baud: 9600, demodSampleRate: 48_000,
                              isTxCapable: false, detectorFilter: .sharpLowpass)
        }
    }

    var isTxCapable: Bool { parameters.isTxCapable }
    var baud: Double { parameters.baud }

    /// Modes the operator can pick today; 9600 joins when its demodulator ships.
    static var selectable: [ModemMode] { [.afsk1200, .afsk300] }

    var title: String {
        switch self {
        case .afsk1200: return "1200 bd AFSK (VHF/UHF FM)"
        case .afsk300: return "300 bd AFSK (HF SSB)"
        case .g3ruh9600RxIF: return "9600 bd G3RUH (receive only, 12 kHz IF)"
        }
    }

    /// What the radio must be set to for this mode, in the operator's words.
    var radioSetupNote: String {
        switch self {
        case .afsk1200: return "Radio in FM with data mode on (FM-D), DATA MOD set to USB."
        case .afsk300: return "Radio in USB with data mode on (USB-D), a filter of at least 1.8 kHz; tune 1.7 kHz below the channel."
        case .g3ruh9600RxIF: return "USB AF/IF Output set to IF. Receive only on this radio."
        }
    }
}
