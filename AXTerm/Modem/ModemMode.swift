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
    }

    var parameters: Parameters {
        switch self {
        case .afsk1200:
            return Parameters(markHz: 1200, spaceHz: 2200, baud: 1200, demodSampleRate: 12_000, isTxCapable: true)
        case .afsk300:
            return Parameters(markHz: 1600, spaceHz: 1800, baud: 300, demodSampleRate: 12_000, isTxCapable: true)
        case .g3ruh9600RxIF:
            return Parameters(markHz: 0, spaceHz: 0, baud: 9600, demodSampleRate: 48_000, isTxCapable: false)
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
