//
//  MobilinkdTNC.swift
//  AXTerm
//
//  Created by AXTerm on 2/14/26.
//

import Foundation

/// Helper for generating Mobilinkd TNC4 specific KISS frames.
/// Based on Mobilinkd TNC4 Firmware protocols.
enum MobilinkdTNC {
    
    // MARK: - Constants
    
    static let KISS_FEND: UInt8 = 0xC0
    static let CMD_HARDWARE: UInt8 = 0x06
    
    // Hardware Commands (from KissHardware.hpp in the tnc4-firmware submodule)
    static let SET_OUTPUT_GAIN: UInt8 = 0x01 // TX Volume, uint16 0-256. Mobilinkd: above 64 is too hot for an HT's mic input.
    static let SET_INPUT_GAIN: UInt8 = 0x02  // RX gain step 0-4: 0, 6, 12, 18, 24 dB
    static let POLL_INPUT_LEVEL: UInt8 = 0x04   // Returns Vpp/Vavg/Vmin/Vmax
    static let GET_BATTERY_LEVEL: UInt8 = 0x06
    static let STREAM_AMPLIFIED_INPUT: UInt8 = 29 // Scope data
    static let ADJUST_INPUT_LEVELS: UInt8 = 0x2B  // Runs firmware auto-AGC (43)
    static let RESET: UInt8 = 0x0B                // Restarts the demodulator
    static let GET_OUTPUT_GAIN: UInt8 = 0x0C
    static let GET_FIRMWARE_VERSION: UInt8 = 0x28 // Replies with an ASCII version, e.g. "2.5.14"

    // Extended Commands. These ride inside a hardware frame: C0 06 C1 xx ... C0.
    static let EXT_CMD_PREFIX: UInt8 = 0xC1
    static let EXT_GET_MODEM_TYPE: UInt8 = 0x81
    static let EXT_SET_MODEM_TYPE: UInt8 = 0x82

    // None of the SET commands above is written to the TNC4's flash. The
    // firmware stores settings only on SAVE_EEPROM_SETTINGS (42), which AXTerm
    // never sends, so a power cycle always brings back what the owner saved.

    // Modem Types
    enum ModemType: UInt8, CaseIterable, Identifiable {
        case afsk1200 = 1
        case fsk9600 = 3
        case m17 = 5
        
        var id: UInt8 { rawValue }
        
        var description: String {
            switch self {
            case .afsk1200: return "1200 Baud (AFSK)"
            case .fsk9600: return "9600 Baud (FSK)"
            case .m17: return "M17 (4-FSK)"
            }
        }
    }
    
    // MARK: - Frame Generators
    
    /// Generates a frame to set the Output Gain (TX Volume).
    /// - Parameter level: 0-256, sent as a big-endian uint16.
    static func setOutputGain(_ level: UInt16) -> [UInt8] {
        [KISS_FEND, CMD_HARDWARE, SET_OUTPUT_GAIN, UInt8(level >> 8), UInt8(level & 0xFF), KISS_FEND]
    }

    /// Generates a frame to set the Input Gain (RX Volume).
    /// - Parameter level: gain step 0-4 (0 to 24 dB in 6 dB steps).
    ///
    /// The TNC4 answers with its input gain, then re-measures its input centre
    /// for about a second and starts streaming input levels. Send `reset()`
    /// afterwards to get back to decoding packets.
    static func setInputGain(_ level: UInt16) -> [UInt8] {
        [KISS_FEND, CMD_HARDWARE, SET_INPUT_GAIN, UInt8(level >> 8), UInt8(level & 0xFF), KISS_FEND]
    }

    /// Generates a frame to set the Modem Type.
    ///
    /// An extended command, so it goes inside a hardware frame: the firmware
    /// dispatches it from the SetHardware handler when the first byte is above
    /// 0xC0. Without the 06 in front the TNC4 reads it as an unknown KISS
    /// command and ignores it.
    static func setModemType(_ type: ModemType) -> [UInt8] {
        [KISS_FEND, CMD_HARDWARE, EXT_CMD_PREFIX, EXT_SET_MODEM_TYPE, type.rawValue, KISS_FEND]
    }

    static func getModemType() -> [UInt8] {
        [KISS_FEND, CMD_HARDWARE, EXT_CMD_PREFIX, EXT_GET_MODEM_TYPE, KISS_FEND]
    }

    static func getOutputGain() -> [UInt8] {
        [KISS_FEND, CMD_HARDWARE, GET_OUTPUT_GAIN, KISS_FEND]
    }

    static func getInputGain() -> [UInt8] {
        [KISS_FEND, CMD_HARDWARE, GET_INPUT_GAIN, KISS_FEND]
    }

    static func getFirmwareVersion() -> [UInt8] {
        [KISS_FEND, CMD_HARDWARE, GET_FIRMWARE_VERSION, KISS_FEND]
    }
    
    /// Generates a frame to request battery level.
    ///
    /// On its own this stops the TNC4 receiving: the battery is read by the
    /// audio task, and any message to that task ends the demodulator, which
    /// only a RESET, the end of a transmission or a new connection restarts
    /// (AudioInput.cpp, startAudioInputTask). Use `pollBatteryLevelAndResume()`.
    static func pollBatteryLevel() -> [UInt8] {
        return [KISS_FEND, CMD_HARDWARE, GET_BATTERY_LEVEL, KISS_FEND]
    }

    /// A battery poll followed by RESET in the same write, so the TNC4 goes
    /// back to decoding once it has read the battery.
    ///
    /// AXTerm used to poll the battery five seconds after connecting and
    /// every minute after that, which left the receiver off until the next
    /// transmission or the startup watchdog's RESET.
    static func pollBatteryLevelAndResume() -> [UInt8] {
        pollBatteryLevel() + reset()
    }

    /// How often to ask. Each poll stops the demodulator for a moment and a
    /// battery doesn't move fast, so not often.
    static let batteryPollInterval: TimeInterval = 300

    /// Generates a frame to poll audio input levels (Vpp/Vavg/Vmin/Vmax).
    static func pollInputLevel() -> [UInt8] {
        return [KISS_FEND, CMD_HARDWARE, POLL_INPUT_LEVEL, KISS_FEND]
    }

    /// Generates a frame to trigger the firmware's auto-AGC adjustment.
    /// NOTE: This stops the demodulator during calibration. Send reset() after to restart.
    static func adjustInputLevels() -> [UInt8] {
        return [KISS_FEND, CMD_HARDWARE, ADJUST_INPUT_LEVELS, KISS_FEND]
    }

    /// Generates a frame to restart the demodulator.
    /// Must be sent after POLL_INPUT_LEVEL or ADJUST_INPUT_LEVELS to resume packet reception.
    static func reset() -> [UInt8] {
        return [KISS_FEND, CMD_HARDWARE, RESET, KISS_FEND]
    }
    
    // MARK: - Parsers
    
    /// Parses the battery level from a hardware response frame.
    /// Expected format: [CMD_HARDWARE, GET_BATTERY_LEVEL, HighByte, LowByte]
    /// Returns voltage in millivolts, or nil if invalid.
    static func parseBatteryLevel(_ data: Data) -> Int? {
        guard data.count >= 4,
              data[0] == CMD_HARDWARE,
              data[1] == GET_BATTERY_LEVEL else {
            return nil
        }
        
        let high = Int(data[2])
        let low = Int(data[3])
        return (high << 8) + low
    }

    /// Parses audio input level from a hardware response frame.
    /// Expected format: [CMD_HARDWARE, POLL_INPUT_LEVEL, Vpp_hi, Vpp_lo, Vavg_hi, Vavg_lo, Vmin_hi, Vmin_lo, Vmax_hi, Vmax_lo]
    /// Returns MobilinkdInputLevel or nil if invalid.
    static func parseInputLevel(_ data: Data) -> MobilinkdInputLevel? {
        guard data.count >= 10,
              data[0] == CMD_HARDWARE,
              data[1] == POLL_INPUT_LEVEL else {
            return nil
        }

        let vpp  = UInt16(data[2]) << 8 | UInt16(data[3])
        let vavg = UInt16(data[4]) << 8 | UInt16(data[5])
        let vmin = UInt16(data[6]) << 8 | UInt16(data[7])
        let vmax = UInt16(data[8]) << 8 | UInt16(data[9])

        return MobilinkdInputLevel(vpp: vpp, vavg: vavg, vmin: vmin, vmax: vmax)
    }
    static let GET_INPUT_GAIN: UInt8 = 0x0D       // Reported by TNC after Auto-Adjust

    /// Parses the output gain from a hardware response frame.
    /// Expected format: [CMD_HARDWARE, GET_OUTPUT_GAIN, HighByte, LowByte]
    static func parseOutputGain(_ data: Data) -> Int? {
        guard data.count >= 4, data[0] == CMD_HARDWARE, data[1] == GET_OUTPUT_GAIN else { return nil }
        return Int(data[2]) << 8 | Int(data[3])
    }

    /// Parses the modem type from an extended reply: [CMD_HARDWARE, 0xC1, 0x81, type].
    static func parseModemType(_ data: Data) -> UInt8? {
        guard data.count >= 4, data[0] == CMD_HARDWARE,
              data[1] == EXT_CMD_PREFIX, data[2] == EXT_GET_MODEM_TYPE else { return nil }
        return data[3]
    }

    /// Parses the firmware version string: [CMD_HARDWARE, GET_FIRMWARE_VERSION, ASCII...].
    static func parseFirmwareVersion(_ data: Data) -> String? {
        guard data.count >= 3, data[0] == CMD_HARDWARE, data[1] == GET_FIRMWARE_VERSION else { return nil }
        let text = String(decoding: data.dropFirst(2).prefix { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// Parses the input gain from a hardware response frame.
    /// Expected format: [CMD_HARDWARE, GET_INPUT_GAIN, HighByte, LowByte]
    /// Returns gain level (0-N) or nil if invalid.
    static func parseInputGain(_ data: Data) -> Int? {
        guard data.count >= 4,
              data[0] == CMD_HARDWARE,
              data[1] == GET_INPUT_GAIN else {
            return nil
        }
        
        let high = Int(data[2])
        let low = Int(data[3])
        return (high << 8) + low
    }
}

/// Audio input level readings from TNC4 ADC
struct MobilinkdInputLevel: Equatable, Sendable {
    let vpp: UInt16    // Peak-to-peak voltage (ADC units)
    let vavg: UInt16   // Average (DC offset)
    let vmin: UInt16   // Minimum
    let vmax: UInt16   // Maximum
}

/// Configuration payload for Mobilinkd TNC4
///
/// The defaults are the firmware's own (KissHardware.hpp), so a profile that
/// never touched them asks the TNC4 for nothing it doesn't already have.
struct MobilinkdConfig: Hashable, Sendable {
    var modemType: MobilinkdTNC.ModemType = .afsk1200
    var outputGain: UInt8 = 63      // TX Volume (0-255); firmware default
    var inputGain: UInt8 = 0        // RX gain step (0-4); firmware default
    var isBatteryMonitoringEnabled: Bool = true
}
