import Foundation

/// How the built-in modem keys the transmitter.
nonisolated enum ModemPTTMethod: String, Codable, CaseIterable, Sendable {
    /// The CI-V transmit command — exact, and it lets us read the radio too.
    case civ
    /// RTS on the CI-V serial port; the radio's USB SEND set to USB (A) RTS.
    case rts
    /// DTR likewise.
    case dtr
    /// VOX or an external keyer: the modem only plays audio.
    case none

    var title: String {
        switch self {
        case .civ: return "CI-V command"
        case .rts: return "Serial RTS"
        case .dtr: return "Serial DTR"
        case .none: return "None (VOX)"
        }
    }

    var explanation: String {
        switch self {
        case .civ: return "AXTerm keys the radio over CI-V. Set the radio's USB SEND to OFF."
        case .rts: return "Set the radio's USB SEND to USB (A) RTS."
        case .dtr: return "Set the radio's USB SEND to USB (A) DTR."
        case .none: return "The radio keys itself on audio. Timing is at the mercy of its VOX delay."
        }
    }
}

/// How the radio itself is reached: its USB cable (a sound codec plus a
/// CI-V serial port) or its WLAN (Icom's network protocol, which carries
/// audio and CI-V together).
nonisolated enum ModemRigLink: String, Codable, CaseIterable, Sendable {
    case usb
    case lan

    var title: String {
        switch self {
        case .usb: return "USB cable"
        case .lan: return "Wi-Fi (Icom LAN)"
        }
    }
}

/// Everything a modem radio's link needs, read off the profile once — the
/// profile never depends on DSP or CI-V types, and the link never sees the
/// profile.
nonisolated struct ModemLinkConfig: Equatable, Sendable {
    var rigLink: ModemRigLink = .usb
    var mode: ModemMode = .afsk1200
    var audioInputDeviceUID = ""
    var audioInputDeviceName = ""
    var audioOutputDeviceUID = ""
    var audioOutputDeviceName = ""
    var inputChannel: ModemInputChannel = .left
    var kissPort: UInt8 = 0

    var civSerialPath = ""
    var lanHost = ""
    var lanControlPort: UInt16 = 50001
    var lanUsername = ""
    /// Runtime only: read from the Keychain, never on the profile.
    var lanPassword = ""
    var civAddress: UInt8 = 0xA4
    var civControllerAddress: UInt8 = 0xE0
    var pttMethod: ModemPTTMethod = .civ

    var txDelayMs = 300
    var txTailMs = 100
    var persistence: UInt8 = 63
    var slotTimeMs = 100
    /// 0…100, mapped to −40…0 dBFS; 85 is the −6 dBFS default.
    var txAudioLevel = 85

    var followsRadioFrequency = true
    var setsRadioModeOnConnect = false
    var maxTransmitSeconds = 30

    init() {}

    /// Whether CI-V is in play at all. Over the WLAN it always is: the
    /// control channel is the connection.
    var usesRig: Bool { rigLink == .lan || !civSerialPath.isEmpty }

    /// The network session's settings, for a Wi-Fi radio.
    var lanConfiguration: IcomLANSession.Configuration {
        var c = IcomLANSession.Configuration(host: lanHost, username: lanUsername, password: lanPassword)
        c.controlPort = lanControlPort
        return c
    }

    var txLevelDBFS: Float { -40 + 40 * Float(max(0, min(100, txAudioLevel))) / 100 }

    var softModemConfiguration: SoftModemConfiguration {
        var c = SoftModemConfiguration()
        c.mode = mode
        c.inputDeviceUID = audioInputDeviceUID
        c.outputDeviceUID = audioOutputDeviceUID
        c.inputChannel = inputChannel
        c.kissPort = kissPort
        c.txDelayMs = txDelayMs
        c.txTailMs = txTailMs
        c.persist = persistence
        c.slotTimeMs = slotTimeMs
        c.txLevelDBFS = txLevelDBFS
        c.pttWatchdogSeconds = Double(maxTransmitSeconds)
        return c
    }

    /// Changes that need the link torn down and rebuilt: the devices, the
    /// mode, the CI-V port and how the transmitter is keyed. Levels and
    /// timing apply in place.
    func requiresReopen(from old: ModemLinkConfig) -> Bool {
        rigLink != old.rigLink
            || lanHost != old.lanHost
            || lanControlPort != old.lanControlPort
            || lanUsername != old.lanUsername
            || lanPassword != old.lanPassword
            || audioInputDeviceUID != old.audioInputDeviceUID
            || audioOutputDeviceUID != old.audioOutputDeviceUID
            || inputChannel != old.inputChannel
            || mode != old.mode
            || civSerialPath != old.civSerialPath
            || civAddress != old.civAddress
            || pttMethod != old.pttMethod
    }
}
