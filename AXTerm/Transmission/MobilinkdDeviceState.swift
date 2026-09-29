//
//  MobilinkdDeviceState.swift
//  AXTerm
//
//  Everything a Mobilinkd TNC4 reports about itself, assembled from the
//  hardware replies it sends. The command set and reply formats come from the
//  firmware (tnc4-firmware Core/TNC/KissHardware.hpp and .cpp), cross-checked
//  against Mobilinkd's own configuration apps (Apache-2.0).
//

import Foundation

/// One hardware reply from the TNC4, decoded.
///
/// Every reply is `[0x06, code, value...]`, or `[0x06, 0xC1, code, value...]`
/// for extended ones. 16-bit values are big-endian and twists are signed.
nonisolated enum MobilinkdReply: Equatable, Sendable {
    case apiVersion(UInt16)
    case capabilities(UInt16)
    case batteryMillivolts(Int)
    case firmwareVersion(String)
    case hardwareVersion(String)
    case serialNumber(String)
    case macAddress(String)
    case outputGain(Int)
    case outputTwist(Int)
    case inputGain(Int)
    case inputTwist(Int)
    case inputGainRange(min: Int?, max: Int?)
    case inputTwistRange(min: Int?, max: Int?)
    case txDelayMs(Int)
    case persistence(Int)
    case slotTimeMs(Int)
    case txTailMs(Int)
    case fullDuplex(Bool)
    case pttMultiplex(Bool)
    case passall(Bool)
    case rxReversePolarity(Bool)
    case txReversePolarity(Bool)
    case usbPowerOn(Bool)
    case usbPowerOff(Bool)
    case modemType(UInt8)
    case supportedModemTypes([UInt8])
    case dateTime(Date)
    case errorMessage(String)
    case inputLevel(MobilinkdInputLevel)
    case saved

    // swiftlint:disable:next cyclomatic_complexity
    static func parse(_ frame: Data) -> MobilinkdReply? {
        let b = Array(frame)
        guard b.count >= 2, b[0] == MobilinkdTNC.CMD_HARDWARE else { return nil }
        let v = Array(b.dropFirst(2))
        // Exact lengths, as the firmware's reply8/reply16 send them. This is
        // what keeps another TNC's text answer from reading as a setting:
        // Direwolf's "TNC:DIREWOLF 1.8" starts with 'T', which is 84, the
        // RX-polarity code, but carries far more than one byte.
        func u8() -> Int? { v.count == 1 ? Int(v[0]) : nil }
        func s8() -> Int? { v.count == 1 ? Int(Int8(bitPattern: v[0])) : nil }
        func u16() -> Int? { v.count == 2 ? Int(v[0]) << 8 | Int(v[1]) : nil }
        func flag() -> Bool? { v.count == 1 ? v[0] != 0 : nil }
        func text() -> String? {
            let s = String(decoding: v.prefix { $0 != 0 }, as: UTF8.self)
            return s.isEmpty ? nil : s
        }

        switch b[1] {
        case 123: return u16().map { .apiVersion(UInt16($0)) }
        case 126: return u16().map { .capabilities(UInt16($0)) }
        case 6: return u16().map(MobilinkdReply.batteryMillivolts)
        case 40: return text().map(MobilinkdReply.firmwareVersion)
        case 41: return text().map(MobilinkdReply.hardwareVersion)
        case 47: return text().map(MobilinkdReply.serialNumber)
        case 48:
            guard v.count == 6 else { return nil }
            return .macAddress(v.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":"))
        case 12: return u16().map(MobilinkdReply.outputGain)
        case 27: return u8().map(MobilinkdReply.outputTwist)
        case 13: return u16().map(MobilinkdReply.inputGain)
        case 25: return s8().map(MobilinkdReply.inputTwist)
        case 124: return u16().map { .inputGainRange(min: $0, max: nil) }
        case 125: return u16().map { .inputGainRange(min: nil, max: $0) }
        case 121: return s8().map { .inputTwistRange(min: $0, max: nil) }
        case 122: return s8().map { .inputTwistRange(min: nil, max: $0) }
        case 33: return u8().map { .txDelayMs($0 * 10) }
        case 34: return u8().map(MobilinkdReply.persistence)
        case 35: return u8().map { .slotTimeMs($0 * 10) }
        case 36: return u8().map { .txTailMs($0 * 10) }
        case 37: return flag().map(MobilinkdReply.fullDuplex)
        case 80: return flag().map(MobilinkdReply.pttMultiplex)
        case 82: return flag().map(MobilinkdReply.passall)
        case 84: return flag().map(MobilinkdReply.rxReversePolarity)
        case 86: return flag().map(MobilinkdReply.txReversePolarity)
        case 74: return flag().map(MobilinkdReply.usbPowerOn)
        case 76: return flag().map(MobilinkdReply.usbPowerOff)
        case 49: return v.count == 7 ? MobilinkdTNC.decodeDateTime(v).map(MobilinkdReply.dateTime) : nil
        case 51: return text().map(MobilinkdReply.errorMessage)
        case 4: return v.count == 8 ? MobilinkdTNC.parseInputLevel(frame).map(MobilinkdReply.inputLevel) : nil
        case 42: return v.count == 1 ? .saved : nil
        case MobilinkdTNC.EXT_CMD_PREFIX:
            guard b.count >= 3 else { return nil }
            let ev = Array(b.dropFirst(3))
            switch b[2] {
            case MobilinkdTNC.EXT_GET_MODEM_TYPE: return ev.first.map(MobilinkdReply.modemType)
            case MobilinkdTNC.EXT_GET_MODEM_TYPES: return .supportedModemTypes(ev)
            default: return nil
            }
        default: return nil
        }
    }
}

/// What AXTerm knows about a connected TNC4. Every field is optional because
/// it fills in reply by reply.
nonisolated struct MobilinkdDeviceState: Equatable, Sendable {
    var apiVersion: UInt16?
    var capabilities: UInt16?
    var batteryMillivolts: Int?
    var firmwareVersion: String?
    var hardwareVersion: String?
    var serialNumber: String?
    var macAddress: String?
    var outputGain: Int?
    var outputTwist: Int?
    var inputGain: Int?
    var inputTwist: Int?
    var minInputGain: Int?
    var maxInputGain: Int?
    var minInputTwist: Int?
    var maxInputTwist: Int?
    var txDelayMs: Int?
    var persistence: Int?
    var slotTimeMs: Int?
    var txTailMs: Int?
    var fullDuplex: Bool?
    var pttMultiplex: Bool?
    var passall: Bool?
    var rxReversePolarity: Bool?
    var txReversePolarity: Bool?
    var usbPowerOn: Bool?
    var usbPowerOff: Bool?
    var modemType: UInt8?
    var supportedModemTypes: [UInt8]?
    var dateTime: Date?
    var errorMessage: String?
    var inputLevel: MobilinkdInputLevel?
    var inputLevelAt: Date?
    var lastSavedAt: Date?

    /// The TNC4 can store its settings in flash (CAP_EEPROM_SAVE).
    var canSave: Bool { (capabilities ?? 0) & 0x0002 != 0 }

    mutating func apply(_ reply: MobilinkdReply, at now: Date = Date()) {
        switch reply {
        case .apiVersion(let x): apiVersion = x
        case .capabilities(let x): capabilities = x
        case .batteryMillivolts(let x): batteryMillivolts = x
        case .firmwareVersion(let x): firmwareVersion = x
        case .hardwareVersion(let x): hardwareVersion = x
        case .serialNumber(let x): serialNumber = x
        case .macAddress(let x): macAddress = x
        case .outputGain(let x): outputGain = x
        case .outputTwist(let x): outputTwist = x
        case .inputGain(let x): inputGain = x
        case .inputTwist(let x): inputTwist = x
        case .inputGainRange(let lo, let hi):
            if let lo { minInputGain = lo }
            if let hi { maxInputGain = hi }
        case .inputTwistRange(let lo, let hi):
            if let lo { minInputTwist = lo }
            if let hi { maxInputTwist = hi }
        case .txDelayMs(let x): txDelayMs = x
        case .persistence(let x): persistence = x
        case .slotTimeMs(let x): slotTimeMs = x
        case .txTailMs(let x): txTailMs = x
        case .fullDuplex(let x): fullDuplex = x
        case .pttMultiplex(let x): pttMultiplex = x
        case .passall(let x): passall = x
        case .rxReversePolarity(let x): rxReversePolarity = x
        case .txReversePolarity(let x): txReversePolarity = x
        case .usbPowerOn(let x): usbPowerOn = x
        case .usbPowerOff(let x): usbPowerOff = x
        case .modemType(let x): modemType = x
        case .supportedModemTypes(let x): supportedModemTypes = x
        case .dateTime(let x): dateTime = x
        case .errorMessage(let x): errorMessage = x
        case .inputLevel(let x): inputLevel = x; inputLevelAt = now
        case .saved: lastSavedAt = now
        }
    }

    // MARK: Battery

    /// Battery charge as 0...1, on the scale Mobilinkd's iOS app uses
    /// (3.3 V empty to 4.2 V full).
    var batteryFraction: Double? {
        batteryMillivolts.map { min(1, max(0, (Double($0) - 3300) / 900)) }
    }
}
