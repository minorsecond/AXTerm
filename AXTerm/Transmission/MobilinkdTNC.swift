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
    /// The firmware's own input auto-adjust (43). Known so its replies can be
    /// recognized; AXTerm deliberately has no way to send it. It saves the
    /// gain it picks to the TNC4's memory, changing it for every radio the
    /// TNC4 serves, and in firmware 2.5.x it judges 14-bit readings against a
    /// 12-bit full scale (AudioLevel.hpp: vref = 4095): it lands about two
    /// steps low, never sees clipping at the top, and loops with no timeout
    /// while the input clips at the bottom. MobilinkdLevelAssistant does the
    /// job instead, per radio, saving nothing.
    static let ADJUST_INPUT_LEVELS: UInt8 = 0x2B
    static let RESET: UInt8 = 0x0B                // Restarts the demodulator
    static let GET_OUTPUT_GAIN: UInt8 = 0x0C
    static let GET_FIRMWARE_VERSION: UInt8 = 0x28 // Replies with an ASCII version, e.g. "2.5.14"

    // Extended Commands. These ride inside a hardware frame: C0 06 C1 xx ... C0.
    static let EXT_CMD_PREFIX: UInt8 = 0xC1
    static let EXT_GET_MODEM_TYPE: UInt8 = 0x81
    static let EXT_SET_MODEM_TYPE: UInt8 = 0x82
    static let EXT_GET_MODEM_TYPES: UInt8 = 0x83  // Lists the types this firmware accepts

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
    /// The TNC4 answers with its input gain, then re-measures its input center
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

    // MARK: Configuration (opcodes from KissHardware.hpp)

    private static func hw(_ code: UInt8, _ args: [UInt8] = []) -> [UInt8] {
        [KISS_FEND, CMD_HARDWARE, code] + args + [KISS_FEND]
    }

    /// Every setting, version and capability in one burst of replies.
    ///
    /// AXTerm doesn't send this. It queues a battery and a twist measurement
    /// on the audio task, and on firmware 2.5.14 that has left the TNC4 hung
    /// until it rebooted. See MobilinkdSession.statusRequests.
    static func getAllValues() -> [UInt8] { hw(127) }

    /// Input levels as a stream of `[06 04 Vpp Vavg Vmin Vmax]` replies until
    /// another audio command arrives. The demodulator is off while streaming;
    /// end with `reset()` to get back to packets.
    static func streamInputLevel() -> [UInt8] { hw(5) }

    /// Test tones. These key the radio and keep it keyed until `stopTX()` or
    /// any hardware command other than an output gain or twist change.
    static func sendMark() -> [UInt8] { hw(7) }
    static func sendSpace() -> [UInt8] { hw(8) }
    static func sendBoth() -> [UInt8] { hw(9) }
    static func stopTX() -> [UInt8] { hw(10) }

    /// Input twist in dB, -3...9 on the TNC4. Starts a level stream, so
    /// follow with `reset()`.
    static func setInputTwist(_ dB: Int) -> [UInt8] { hw(24, [UInt8(bitPattern: Int8(clamping: dB))]) }

    /// Output twist 0...100; 50 is flat, lower cuts 2200 Hz, higher cuts 1200 Hz.
    static func setOutputTwist(_ value: Int) -> [UInt8] { hw(26, [UInt8(clamping: max(0, min(100, value)))]) }

    /// PTT style: multiplex (PTT on the mic line, most handhelds) or simplex
    /// (a separate PTT line). The firmware sends no reply to this one.
    static func setPTTMultiplex(_ multiplex: Bool) -> [UInt8] { hw(79, [multiplex ? 1 : 0]) }
    static func getPTTChannel() -> [UInt8] { hw(80) }
    static func getOutputTwist() -> [UInt8] { hw(27) }
    static func getHardwareVersion() -> [UInt8] { hw(41) }
    static func getSerialNumber() -> [UInt8] { hw(47) }
    static func getCapabilities() -> [UInt8] { hw(126) }
    static func getPassall() -> [UInt8] { hw(82) }
    static func getRxReversePolarity() -> [UInt8] { hw(84) }
    static func getTxReversePolarity() -> [UInt8] { hw(86) }
    static func getUSBPowerOn() -> [UInt8] { hw(74) }
    static func getUSBPowerOff() -> [UInt8] { hw(76) }
    /// GET_TXDELAY (33), GET_PERSIST (34), GET_TIMESLOT (35), GET_TXTAIL (36).
    static func getTimingValue(_ code: UInt8) -> [UInt8] { hw(code) }
    static func getModemTypes() -> [UInt8] { [KISS_FEND, CMD_HARDWARE, EXT_CMD_PREFIX, EXT_GET_MODEM_TYPES, KISS_FEND] }
    static func getInputTwist() -> [UInt8] { hw(25) }

    static func setPassall(_ on: Bool) -> [UInt8] { hw(81, [on ? 1 : 0]) }
    static func setRxReversePolarity(_ on: Bool) -> [UInt8] { hw(83, [on ? 1 : 0]) }
    static func setTxReversePolarity(_ on: Bool) -> [UInt8] { hw(85, [on ? 1 : 0]) }
    static func setUSBPowerOn(_ on: Bool) -> [UInt8] { hw(73, [on ? 1 : 0]) }
    static func setUSBPowerOff(_ on: Bool) -> [UInt8] { hw(75, [on ? 1 : 0]) }

    /// Write the current settings to the TNC4's flash, making them what it
    /// starts with from now on, with every radio. Answered with `06 2A 20`.
    static func saveEEPROM() -> [UInt8] { hw(SAVE_EEPROM) }
    static let SAVE_EEPROM: UInt8 = 42

    static func setDateTime(_ date: Date) -> [UInt8] { hw(50, encodeDateTime(date)) }

    // MARK: Date and time

    /// The RTC's seven BCD bytes: YY MM DD weekday HH MM SS, in UTC, with
    /// weekday 1 (Monday) to 7 (Sunday) as the STM32 RTC counts it.
    static func encodeDateTime(_ date: Date) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
        func bcd(_ n: Int) -> UInt8 { UInt8((n / 10) << 4 | (n % 10)) }
        let weekday = ((c.weekday ?? 1) + 5) % 7 + 1   // Calendar: 1 = Sunday
        return [bcd((c.year ?? 2000) % 100), bcd(c.month ?? 1), bcd(c.day ?? 1), bcd(weekday),
                bcd(c.hour ?? 0), bcd(c.minute ?? 0), bcd(c.second ?? 0)]
    }

    static func decodeDateTime(_ bytes: [UInt8]) -> Date? {
        guard bytes.count >= 7 else { return nil }
        func dec(_ b: UInt8) -> Int? {
            let hi = Int(b >> 4), lo = Int(b & 0x0F)
            return hi < 10 && lo < 10 ? hi * 10 + lo : nil
        }
        guard let yy = dec(bytes[0]), let mo = dec(bytes[1]), let dd = dec(bytes[2]),
              let hh = dec(bytes[4]), let mi = dec(bytes[5]), let ss = dec(bytes[6]) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2000 + yy, month: mo, day: dd, hour: hh, minute: mi, second: ss))
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

    /// Generates a frame to restart the demodulator.
    /// Must be sent after POLL_INPUT_LEVEL or STREAM_INPUT_LEVEL to resume packet reception.
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

        // A minimum above the maximum came from no samples at all. The
        // firmware's level stream sends one when no ADC block arrives within
        // its 1 s wait: vmin and vmax keep their starting values (0xFFFF and
        // 0, shifted to 0xFFFC and 0), Vpp wraps to 4 and Vavg divides by
        // zero (Core/TNC/AudioInput.cpp, streamLevels). Taken as a reading
        // it is near-silence, which no input produced.
        guard vmin <= vmax else { return nil }

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

    /// The TNC4's ADC is 12 bits, oversampled 16 times and shifted right 2,
    /// so its samples are 14 bits, 0...16383 (tnc4-firmware Core/Src/main.c,
    /// MX_ADC2_Init).
    static let adcMaximum = 16_383
    /// Every level is shifted left by the demodulator's ADC exponent before
    /// it is sent: 2 for AFSK 1200, 9600 and M17 (Core/TNC/AudioInput.cpp,
    /// streamLevels and pollAmplifiedInputLevel).
    static let adcExponent = 2
    /// The largest value a report can carry: 65,532, in steps of 4.
    static let fullScale = adcMaximum << adcExponent
    /// A maximum at or above this is at the top rail: within about 33 ADC
    /// counts of it.
    static let topRail = 65_400

    /// Peak to peak as a share of the range.
    var fraction: Double { Double(vpp) / Double(Self.fullScale) }

    /// The input touched an end of the ADC's range. The firmware's own gain
    /// adjustment treats a minimum of 0 as clipping the same way.
    var clipped: Bool { vmin == 0 || Int(vmax) >= Self.topRail }
}

/// What a link needs to know to treat its TNC as a Mobilinkd.
///
/// On Bluetooth LE the link recognizes a Mobilinkd by its service UUID; on
/// serial the operator says so, and this being non-nil is how.
struct MobilinkdConfig: Hashable, Sendable {
    /// The TNC4 settings this radio's profile manages.
    var settings = MobilinkdSettings()
    var isBatteryMonitoringEnabled: Bool = true
}
