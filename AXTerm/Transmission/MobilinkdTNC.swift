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
    
    // Hardware Commands (from KissHardware.hpp)
    static let SET_OUTPUT_GAIN: UInt8 = 0x01 // TX Volume (0-255)
    static let SET_INPUT_GAIN: UInt8 = 0x02  // RX Volume (0-4 on TNC4?) or 0-255 depending on FW.
    static let POLL_INPUT_LEVEL: UInt8 = 0x04   // Returns Vpp/Vavg/Vmin/Vmax
    static let GET_BATTERY_LEVEL: UInt8 = 0x06
    static let STREAM_AMPLIFIED_INPUT: UInt8 = 29 // Scope data
    static let ADJUST_INPUT_LEVELS: UInt8 = 0x2B  // Runs firmware auto-AGC (43)
    static let RESET: UInt8 = 0x0B                // Restarts the demodulator
    
    // Extended Commands (starts with 0xC1)
    static let EXT_CMD_PREFIX: UInt8 = 0xC1
    static let EXT_GET_MODEM_TYPE: UInt8 = 0x81
    static let EXT_SET_MODEM_TYPE: UInt8 = 0x82
    
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
    /// - Parameter level: 0-255
    static func setOutputGain(_ level: UInt8) -> [UInt8] {
        // TNC4 expects 2 bytes for gain (Big Endian uint16_t).
        // Since input is UInt8, High Byte is 0.
        return [KISS_FEND, CMD_HARDWARE, SET_OUTPUT_GAIN, 0x00, level, KISS_FEND]
    }
    
    /// Generates a frame to set the Input Gain (RX Volume).
    /// - Parameter level: TNC4 uses low values (0-4 usually for attenuation/gain steps).
    /// Valid range depends on FW, but safe to send UInt16.
    static func setInputGain(_ level: UInt8) -> [UInt8] {
        return [KISS_FEND, CMD_HARDWARE, SET_INPUT_GAIN, 0x00, level, KISS_FEND]
    }
    
    /// Generates a frame to set the Modem Type.
    static func setModemType(_ type: ModemType) -> [UInt8] {
        // Extended command: FEND | 0xC1 | 0x82 | TYPE | FEND
        return [KISS_FEND, EXT_CMD_PREFIX, EXT_SET_MODEM_TYPE, type.rawValue, KISS_FEND]
    }
    
    /// Generates a frame to request battery level.
    static func pollBatteryLevel() -> [UInt8] {
        return [KISS_FEND, CMD_HARDWARE, GET_BATTERY_LEVEL, KISS_FEND]
    }

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
    
    // ... (existing constants) ...

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
struct MobilinkdConfig: Hashable, Sendable {
    var modemType: MobilinkdTNC.ModemType = .afsk1200
    var outputGain: UInt8 = 128     // TX Volume (0-255)
    var inputGain: UInt8 = 4        // RX Volume (0-4)
    var isBatteryMonitoringEnabled: Bool = true
}
