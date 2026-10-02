//
//  FakeTNC4.swift
//  AXTermTests
//
//  A behavioral model of a Mobilinkd TNC4 on firmware 2.5.14, for tests that
//  have no TNC4 attached.
//
//  Written from reading the firmware (the tnc4-firmware submodule:
//  Core/TNC/KissHardware.cpp, Kiss.cpp, UsbPort.cpp, AudioInput.cpp,
//  AudioLevel.cpp, IOEventTask.cpp). The firmware is all rights reserved, so
//  nothing here is its code; this models what a host sees:
//
//  - KISS frames as the firmware decodes them: a closing FEND does not open
//    the next frame, so frames that share a FEND lose every other one; a type
//    byte with bit 7 set is looped back; TXTAIL (4) is ignored.
//  - Settings in RAM, and a separate EEPROM copy written only by SAVE (0 or
//    42) and ADJUST_INPUT_LEVELS (43), which saves everything in RAM.
//  - Every SETHARDWARE reply in the firmware's format. A SET answers with
//    its GET code; SET_PTT_CHANNEL answers nothing; unknown codes answer
//    nothing.
//  - The audio task: most hardware commands that reach it leave the
//    demodulator stopped, and only RESET (11), the end of a transmission or a
//    new connection starts it again. A frame heard on the air reaches the
//    host only while the demodulator runs, so a test can tell when AXTerm has
//    left the TNC4 deaf.
//  - Test tones key the transmitter until something stops them.
//
//  Replies the firmware sends from its audio task (battery, levels) come
//  back at once here; on the real TNC4 they can arrive between later replies.
//

import Foundation
@testable import AXTerm

final class FakeTNC4 {

    /// What the firmware keeps in its settings block (RAM and EEPROM alike).
    struct Settings: Equatable {
        var txDelay: UInt8 = 30        // 10 ms units
        var persistence: UInt8 = 64
        var slotTime: UInt8 = 10       // 10 ms units
        var txTail: UInt8 = 1
        var duplex: UInt8 = 0
        var modemType: UInt8 = 1       // 1 AFSK1200, 3 FSK9600, 5 M17
        var outputGain: UInt16 = 63
        var inputGain: UInt16 = 0
        var outputTwist: UInt8 = 50
        var inputTwist: Int8 = 0
        var options: UInt8 = 0x10      // simplex PTT, everything else off

        static let pttSimplex: UInt8 = 0x10
        static let usbPowerOn: UInt8 = 0x04
        static let usbPowerOff: UInt8 = 0x08
        static let passall: UInt8 = 0x20
        static let rxReversePolarity: UInt8 = 0x40
        static let txReversePolarity: UInt8 = 0x80

        var pttMultiplex: Bool { options & Self.pttSimplex == 0 }
    }

    /// What the audio task is doing.
    enum Audio: Equatable {
        case demodulating
        /// Stopped: after a poll, a battery read, STOP_TX, GET_ALL_VALUES...
        case idle
        case streamingLevels
        case tone(UInt8)
    }

    // MARK: State

    var ram = Settings()
    private(set) var eeprom = Settings()
    /// Every write of the settings block to EEPROM.
    private(set) var eepromWrites = 0
    private(set) var audio: Audio = .idle
    private(set) var connected = false

    var firmwareVersion = "2.5.14"
    var hardwareVersion = "Mobilinkd TNC4 Rev B"
    var serialNumber = "0123456789AB (1234)"
    var macAddress: [UInt8] = [0x00, 0x1A, 0x7D, 0xDA, 0x71, 0x13]
    var batteryMillivolts: UInt16 = 4218
    /// Vpp, Vavg, Vmin, Vmax as a level report carries them.
    var inputLevel: (vpp: UInt16, vavg: UInt16, vmin: UInt16, vmax: UInt16) = (0x4000, 0x8000, 0x6000, 0xA000)
    /// The battery-backed clock, as its seven BCD bytes.
    private(set) var clock: [UInt8] = [0x26, 0x10, 0x02, 0x05, 0x12, 0x00, 0x00]
    private(set) var clockWrites = 0

    /// AX.25 frames the host asked to transmit, in order.
    private(set) var transmitted: [Data] = []
    /// Hardware command codes that got no answer because the firmware does
    /// not handle them.
    private(set) var unhandled: [UInt8] = []
    /// Frames with a type byte of 0x80 or more, which the firmware loops back.
    private(set) var loopedBack = 0

    /// Bytes to the host.
    var toHost: (Data) -> Void = { _ in }

    var pttKeyed: Bool { if case .tone = audio { return true } else { return false } }

    init(eeprom: Settings = Settings()) {
        self.eeprom = eeprom
        ram = eeprom
    }

    // MARK: Link

    /// USB DTR up or a BLE connection: the firmware reloads nothing (the
    /// settings were read at boot) and starts the demodulator.
    func connect() {
        connected = true
        decoder = .waitingForFEND
        audio = .demodulating
    }

    /// The host went away: TX aborted, demodulator idled.
    func disconnect() {
        connected = false
        audio = .idle
    }

    /// A power cycle: RAM goes back to what EEPROM holds.
    func powerCycle() {
        disconnect()
        ram = eeprom
    }

    /// A frame decoded off the air. The host sees it only while the
    /// demodulator runs.
    @discardableResult
    func heard(_ ax25: Data) -> Bool {
        guard connected, audio == .demodulating else { return false }
        send(type: 0x00, ax25)
        return true
    }

    /// One level report, if the audio task is streaming them.
    func streamTick() {
        guard audio == .streamingLevels else { return }
        sendLevel()
    }

    // MARK: KISS decoding, the firmware's way

    private enum DecoderState { case waitingForFEND, waitingForType, payload, escape }
    private var decoder = DecoderState.waitingForFEND
    private var frameType: UInt8 = 0
    private var frame: [UInt8] = []

    /// Bytes from the host, in pieces of any size.
    func receive(_ bytes: Data) {
        guard connected else { return }   // the port is closed; bytes are dropped
        for byte in bytes {
            switch decoder {
            case .waitingForFEND:
                if byte == KISS.FEND { decoder = .waitingForType }
            case .waitingForType:
                if byte == KISS.FEND { continue }   // repeated FENDs
                frameType = byte                    // taken raw, not unescaped
                frame = []
                decoder = .payload
            case .payload:
                if byte == KISS.FEND {
                    dispatch(type: frameType, frame)
                    decoder = .waitingForFEND       // not .waitingForType
                } else if byte == KISS.FESC {
                    decoder = .escape
                } else {
                    frame.append(byte)
                }
            case .escape:
                switch byte {
                case KISS.TFEND: frame.append(KISS.FEND); decoder = .payload
                case KISS.TFESC: frame.append(KISS.FESC); decoder = .payload
                default: decoder = .waitingForFEND  // a bad escape drops the frame
                }
            }
        }
    }

    private func dispatch(type: UInt8, _ payload: [UInt8]) {
        if type & 0x80 != 0 {
            loopedBack += 1
            return
        }
        switch type & 0x0F {
        case 0x0:
            // No length check on this path: an empty data frame is sent too.
            transmitted.append(Data(payload))
            // A transmission ends a tone and, when it finishes, restarts the
            // demodulator.
            audio = .demodulating
        case 0x1: if let v = payload.first { ram.txDelay = v }
        case 0x2: if let v = payload.first { ram.persistence = v }
        case 0x3: if let v = payload.first { ram.slotTime = v }
        case 0x4: break   // TXTAIL is ignored
        case 0x5: if let v = payload.first { ram.duplex = v }
        case 0x6: if !payload.isEmpty { hardware(payload) }
        default: break
        }
    }

    // MARK: SETHARDWARE

    private func hardware(_ p: [UInt8]) {
        let code = p[0]
        let args = Array(p.dropFirst())
        func u16() -> UInt16 { args.count >= 2 ? UInt16(args[0]) << 8 | UInt16(args[1]) : 0 }
        func u8() -> UInt8 { args.first ?? 0 }

        // Every hardware command but these stops a running test tone.
        if case .tone = audio, ![1, 7, 8, 9, 20, 26].contains(code) { audio = .idle }

        switch code {
        case 0, 42:
            saveSettings()
            reply([42, 32])
        case 1:
            ram.outputGain = u16()
            reply16(12, ram.outputGain)
        case 2:
            ram.inputGain = u16()
            reply16(13, ram.inputGain)
            audio = .streamingLevels
        case 4:
            reply([4, 0])
            sendLevel()
            audio = .idle
        case 5, 29:
            audio = .streamingLevels
        case 6:
            reply16(6, batteryMillivolts)
            audio = .idle
        case 7, 8, 9:
            audio = .tone(code)
        case 10:
            audio = .idle
        case 11:
            audio = .demodulating
        case 12:
            reply16(12, ram.outputGain)
        case 13:
            reply16(13, ram.inputGain)
        case 15:
            break
        case 24:
            ram.inputTwist = Int8(bitPattern: u8())
            reply([25, UInt8(bitPattern: ram.inputTwist)])
            audio = .streamingLevels
        case 25:
            reply([25, UInt8(bitPattern: ram.inputTwist)])
        case 26:
            let v = Int8(bitPattern: u8())
            ram.outputTwist = UInt8(max(0, min(100, Int(v))))
            reply([27, ram.outputTwist])
        case 27:
            reply([27, ram.outputTwist])
        case 33: reply([33, ram.txDelay])
        case 34: reply([34, ram.persistence])
        case 35: reply([35, ram.slotTime])
        case 36: reply([36, ram.txTail])
        case 37: reply([37, ram.duplex])
        case 40: reply([40] + Array(firmwareVersion.utf8))
        case 41: reply([41] + Array(hardwareVersion.utf8))
        case 43:
            // The firmware's auto-adjust: picks gain and twist, then saves
            // the whole settings block, and streams levels.
            saveSettings()
            reply16(13, ram.inputGain)
            reply([25, UInt8(bitPattern: ram.inputTwist)])
            audio = .streamingLevels
        case 44:
            reply([44, 0x00, 0x00, 0x00, 0x00])
            audio = .idle
        case 45, 46:
            audio = .idle
        case 47:
            // The standalone reply is the whole 23-byte buffer, NULs and all.
            var s = Array(serialNumber.utf8.prefix(23))
            while s.count < 23 { s.append(0) }
            reply([47] + s)
        case 49:
            reply([49] + clock)
        case 50:
            if args.count >= 7 { clock = Array(args.prefix(7)); clockWrites += 1 }
            reply([49] + clock)
        case 73: setOption(Settings.usbPowerOn, u8() != 0); reply([74, option(Settings.usbPowerOn)])
        case 74: reply([74, option(Settings.usbPowerOn)])
        case 75: setOption(Settings.usbPowerOff, u8() != 0); reply([76, option(Settings.usbPowerOff)])
        case 76: reply([76, option(Settings.usbPowerOff)])
        case 79:
            setOption(Settings.pttSimplex, u8() == 0)   // no reply
        case 80: reply([80, ram.pttMultiplex ? 1 : 0])
        case 81: setOption(Settings.passall, u8() != 0); reply([82, option(Settings.passall)])
        case 82: reply([82, option(Settings.passall)])
        case 83: setOption(Settings.rxReversePolarity, u8() != 0); reply([84, option(Settings.rxReversePolarity)])
        case 84: reply([84, option(Settings.rxReversePolarity)])
        case 85: setOption(Settings.txReversePolarity, u8() != 0); reply([86, option(Settings.txReversePolarity)])
        case 86: reply([86, option(Settings.txReversePolarity)])
        case 126: reply16(126, 0x100E)
        case 127: allValues()
        case 0xC1...0xFF:
            extended(args)
        default:
            unhandled.append(code)
        }
    }

    private func extended(_ args: [UInt8]) {
        guard let sub = args.first else { return }
        switch sub {
        case 0x81:
            reply([0xC1, 0x81, ram.modemType])
        case 0x82:
            if let type = args.dropFirst().first, [1, 3, 5].contains(type) { ram.modemType = type }
            reply([0xC1, 0x81, ram.modemType])
            audio = .idle
        case 0x83:
            reply([0xC1, 0x83, 1, 3, 5])
        default:
            unhandled.append(sub)
        }
    }

    /// GET_ALL_VALUES, in the firmware's order. It also reads the battery
    /// and measures twist on the audio task, and leaves the demodulator off.
    private func allValues() {
        reply16(123, 0x0202)
        reply16(6, batteryMillivolts)
        reply([76, option(Settings.usbPowerOff)])
        reply([74, option(Settings.usbPowerOn)])
        reply([48] + macAddress)
        reply16(126, 0x100E)
        reply([40] + Array(firmwareVersion.utf8))
        reply([41] + Array(hardwareVersion.utf8))
        reply([47] + Array(serialNumber.utf8))
        reply16(12, ram.outputGain)
        reply([27, ram.outputTwist])
        reply16(13, ram.inputGain)
        reply([25, UInt8(bitPattern: ram.inputTwist)])
        reply([33, ram.txDelay]); reply([34, ram.persistence]); reply([35, ram.slotTime])
        reply([36, ram.txTail]); reply([37, ram.duplex])
        reply([80, ram.pttMultiplex ? 1 : 0])
        reply([82, option(Settings.passall)])
        reply16(124, 0); reply16(125, 4)
        reply([121, UInt8(bitPattern: -3)]); reply([122, 9])
        reply([0xC1, 0x81, ram.modemType])
        reply([0xC1, 0x83, 1, 3, 5])
        reply([49] + clock)
        reply([84, option(Settings.rxReversePolarity)])
        reply([86, option(Settings.txReversePolarity)])
        reply([44, 0x00, 0x00, 0x00, 0x00])
        audio = .idle
    }

    // MARK: Helpers

    private func saveSettings() {
        eeprom = ram
        eepromWrites += 1
    }

    private func option(_ bit: UInt8) -> UInt8 { ram.options & bit != 0 ? 1 : 0 }
    private func setOption(_ bit: UInt8, _ on: Bool) {
        if on { ram.options |= bit } else { ram.options &= ~bit }
    }

    private func sendLevel() {
        let l = inputLevel
        reply([4] + [l.vpp, l.vavg, l.vmin, l.vmax].flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
    }

    private func reply16(_ code: UInt8, _ value: UInt16) {
        reply([code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private func reply(_ payload: [UInt8]) { send(type: 0x06, Data(payload)) }

    private func send(type: UInt8, _ payload: Data) {
        guard connected else { return }
        toHost(Data([KISS.FEND, type]) + KISS.escape(payload) + Data([KISS.FEND]))
    }
}
