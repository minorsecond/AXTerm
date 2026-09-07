import Foundation

/// How a radio's TNC is reached. The raw values are the strings the legacy
/// single-connection setting (`kissTransportType`) has always stored, so a
/// profile and the scalar it mirrors never disagree about spelling.
nonisolated enum RadioTransportKind: String, Codable, CaseIterable, Sendable {
    case tcp = "network"
    case serial = "serial"
    case ble = "ble"
}

/// One radio: a TNC port on a link, operating under a callsign.
///
/// Flat rather than an enum with associated values, on purpose. The
/// Connection pane has always kept every transport's fields at once — switch
/// from TCP to serial and back and the host is still there — and a profile
/// that forgot the host on the way through serial would be a regression the
/// operator felt. The link layer reads the one transport that is current
/// through `kind` and builds its link from those fields
/// (`RadioManager.defaultLinkFactory`); `linkKey` names the byte stream.
///
/// Fields the app does not act on yet (`kissPort`, `callsign`, `autoConnect`,
/// `frequencyHz`) are here because the storage format is versioned and every
/// later phase of multi-radio support keys on them; the settings UI shows a
/// control only once the code behind it exists.
nonisolated struct RadioProfile: Codable, Identifiable, Equatable, Sendable {
    var id: RadioID
    var name: String
    var kind: RadioTransportKind = .tcp

    var host: String = "localhost"
    var port: Int = 8001

    var serialDevicePath: String = ""
    var serialBaudRate: Int = 115200
    var serialAutoReconnect: Bool = true

    var blePeripheralUUID: String = ""
    var blePeripheralName: String = ""
    var bleAutoReconnect: Bool = true

    var mobilinkdEnabled: Bool = false
    var mobilinkdModemType: Int = 1
    var mobilinkdOutputGain: Int = 11
    var mobilinkdInputGain: Int = 0

    var capabilities: TNCCapabilities = TNCCapabilities()

    /// The KISS port nibble this radio answers to on its link. Direwolf
    /// numbers its channels this way; everything else is 0.
    var kissPort: UInt8 = 0
    /// The callsign this radio operates as. Empty means the station callsign.
    var callsign: String = ""
    var enabled: Bool = true
    var autoConnect: Bool = true
    var frequencyHz: Int? = nil

    // MARK: Services on this radio
    // All on by default, so one radio behaves exactly as it always has; the
    // switches are only shown once there are two. "Two of your radios on one
    // frequency should not both beacon" is the case they exist for.
    var sendsBeacons: Bool = true
    var pings: Bool = true
    var announcesNode: Bool = true
    var answersMailbox: Bool = true
    /// The alias this radio's node announces under when the NET/ROM node
    /// identity is per radio. Empty means the station alias.
    var netRomAlias: String = ""
    /// Removed radios are archived, not deleted, so rows that name them keep
    /// resolving to a name.
    var archived: Bool = false

    init(id: RadioID, name: String) {
        self.id = id
        self.name = name
    }

    // MARK: Codable

    /// Every field but the id has a default, so a profile written by an older
    /// build decodes under a newer one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(RadioID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(RadioTransportKind.self, forKey: .kind) ?? .tcp
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8001
        serialDevicePath = try c.decodeIfPresent(String.self, forKey: .serialDevicePath) ?? ""
        serialBaudRate = try c.decodeIfPresent(Int.self, forKey: .serialBaudRate) ?? 115200
        serialAutoReconnect = try c.decodeIfPresent(Bool.self, forKey: .serialAutoReconnect) ?? true
        blePeripheralUUID = try c.decodeIfPresent(String.self, forKey: .blePeripheralUUID) ?? ""
        blePeripheralName = try c.decodeIfPresent(String.self, forKey: .blePeripheralName) ?? ""
        bleAutoReconnect = try c.decodeIfPresent(Bool.self, forKey: .bleAutoReconnect) ?? true
        mobilinkdEnabled = try c.decodeIfPresent(Bool.self, forKey: .mobilinkdEnabled) ?? false
        mobilinkdModemType = try c.decodeIfPresent(Int.self, forKey: .mobilinkdModemType) ?? 1
        mobilinkdOutputGain = try c.decodeIfPresent(Int.self, forKey: .mobilinkdOutputGain) ?? 11
        mobilinkdInputGain = try c.decodeIfPresent(Int.self, forKey: .mobilinkdInputGain) ?? 0
        capabilities = try c.decodeIfPresent(TNCCapabilities.self, forKey: .capabilities) ?? TNCCapabilities()
        kissPort = try c.decodeIfPresent(UInt8.self, forKey: .kissPort) ?? 0
        callsign = try c.decodeIfPresent(String.self, forKey: .callsign) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        frequencyHz = try c.decodeIfPresent(Int.self, forKey: .frequencyHz)
        sendsBeacons = try c.decodeIfPresent(Bool.self, forKey: .sendsBeacons) ?? true
        pings = try c.decodeIfPresent(Bool.self, forKey: .pings) ?? true
        announcesNode = try c.decodeIfPresent(Bool.self, forKey: .announcesNode) ?? true
        answersMailbox = try c.decodeIfPresent(Bool.self, forKey: .answersMailbox) ?? true
        netRomAlias = try c.decodeIfPresent(String.self, forKey: .netRomAlias) ?? ""
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }

    // MARK: Derived

    /// The callsign on the air, SSID included.
    func resolvedCallsign(station: String) -> String {
        let own = callsign.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? station.uppercased() : own.uppercased()
    }

    /// Identifies the byte stream, not the radio: two profiles on one
    /// Direwolf differ by `kissPort` and share a link key.
    var linkKey: String {
        switch kind {
        case .tcp: return "tcp://\(host.lowercased()):\(port)"
        case .serial: return "serial://\(serialDevicePath)"
        case .ble: return "ble://\(blePeripheralUUID.lowercased())"
        }
    }

    /// What has to change for the link to need reopening: the transport and
    /// its addressing, including the serial baud rate. Mobilinkd gains are
    /// deliberately absent — they are applied in place, and reopening the
    /// port for them would disrupt the running demodulator.
    var transportSignature: String {
        switch kind {
        case .tcp: return "tcp://\(host.lowercased()):\(port)#\(kissPort)"
        case .serial: return "serial://\(serialDevicePath)@\(serialBaudRate)#\(kissPort)"
        case .ble: return "ble://\(blePeripheralUUID.lowercased())#\(kissPort)"
        }
    }

    /// Where the link goes, as the operator would say it.
    var displayEndpoint: String {
        switch kind {
        case .tcp:
            return "\(host):\(port)"
        case .serial:
            return serialDevicePath.isEmpty ? "No device" : serialDevicePath
        case .ble:
            if !blePeripheralName.isEmpty { return blePeripheralName }
            return blePeripheralUUID.isEmpty ? "No device" : blePeripheralUUID
        }
    }

    /// The Mobilinkd settings as the links take them, or nil when the TNC is
    /// not a TNC4.
    var mobilinkdConfig: MobilinkdConfig? {
        guard mobilinkdEnabled else { return nil }
        return MobilinkdConfig(
            modemType: MobilinkdTNC.ModemType(rawValue: UInt8(clamping: mobilinkdModemType)) ?? .afsk1200,
            outputGain: UInt8(clamping: mobilinkdOutputGain),
            inputGain: UInt8(clamping: mobilinkdInputGain),
            isBatteryMonitoringEnabled: true)
    }

    // MARK: Legacy single-connection settings

    /// The profile a station had before radios existed, read off the scalar
    /// settings. The id is the fixed primary id so the database migration
    /// that backfills old rows agrees on which radio they belonged to.
    static func migrated(id: RadioID,
                         transportType: String, host: String, port: Int,
                         serialDevicePath: String, serialBaudRate: Int, serialAutoReconnect: Bool,
                         blePeripheralUUID: String, blePeripheralName: String, bleAutoReconnect: Bool,
                         mobilinkdEnabled: Bool, mobilinkdModemType: Int,
                         mobilinkdOutputGain: Int, mobilinkdInputGain: Int,
                         capabilities: TNCCapabilities) -> RadioProfile {
        var radio = RadioProfile(id: id, name: "")
        radio.applyLegacy(transportType: transportType, host: host, port: port,
                          serialDevicePath: serialDevicePath, serialBaudRate: serialBaudRate,
                          serialAutoReconnect: serialAutoReconnect,
                          blePeripheralUUID: blePeripheralUUID, blePeripheralName: blePeripheralName,
                          bleAutoReconnect: bleAutoReconnect,
                          mobilinkdEnabled: mobilinkdEnabled, mobilinkdModemType: mobilinkdModemType,
                          mobilinkdOutputGain: mobilinkdOutputGain, mobilinkdInputGain: mobilinkdInputGain,
                          capabilities: capabilities)
        radio.name = Self.defaultName(for: radio)
        return radio
    }

    private mutating func applyLegacy(transportType: String, host: String, port: Int,
                                      serialDevicePath: String, serialBaudRate: Int, serialAutoReconnect: Bool,
                                      blePeripheralUUID: String, blePeripheralName: String, bleAutoReconnect: Bool,
                                      mobilinkdEnabled: Bool, mobilinkdModemType: Int,
                                      mobilinkdOutputGain: Int, mobilinkdInputGain: Int,
                                      capabilities: TNCCapabilities) {
        kind = RadioTransportKind(rawValue: transportType) ?? .tcp
        self.host = host
        self.port = port
        self.serialDevicePath = serialDevicePath
        self.serialBaudRate = serialBaudRate
        self.serialAutoReconnect = serialAutoReconnect
        self.blePeripheralUUID = blePeripheralUUID
        self.blePeripheralName = blePeripheralName
        self.bleAutoReconnect = bleAutoReconnect
        self.mobilinkdEnabled = mobilinkdEnabled
        self.mobilinkdModemType = mobilinkdModemType
        self.mobilinkdOutputGain = mobilinkdOutputGain
        self.mobilinkdInputGain = mobilinkdInputGain
        self.capabilities = capabilities
    }


    /// A name the operator will recognise before they have typed one. With
    /// one radio the name is never shown, so this only matters the moment a
    /// second is added — and then the operator is already in the pane that
    /// renames it.
    static func defaultName(for radio: RadioProfile) -> String {
        switch radio.kind {
        case .tcp:
            return "Direwolf"
        case .serial:
            let leaf = (radio.serialDevicePath as NSString).lastPathComponent
            let trimmed = leaf.hasPrefix("cu.") ? String(leaf.dropFirst(3)) : leaf
            return trimmed.isEmpty ? "Serial TNC" : trimmed
        case .ble:
            return radio.blePeripheralName.isEmpty ? "Bluetooth TNC" : radio.blePeripheralName
        }
    }
}

/// The fixed identity of the radio a station had before it had several.
nonisolated enum RadioIdentity {
    /// `RadioID.primary`. Kept as a function because the settings store and
    /// the database migration both ask by name; the `defaults` parameter is
    /// accepted and ignored so the call sites need not care that the answer
    /// stopped being minted.
    static func primaryID(defaults: UserDefaults = AppEnvironment.defaults) -> RadioID {
        .primary
    }
}

/// Things two radios cannot both be.
nonisolated enum RadioProfileIssue: Equatable, Sendable {
    /// Two enabled radios claim the same link and port: only one can own the
    /// byte stream.
    case duplicateLink(RadioID, RadioID)
    /// Two enabled radios answer as one address. Legal on different
    /// frequencies, a hazard on the same one.
    case duplicateCallsign(RadioID, RadioID, String)

    static func issues(in radios: [RadioProfile], stationCallsign: String) -> [RadioProfileIssue] {
        let live = radios.filter { !$0.archived && $0.enabled }
        var found: [RadioProfileIssue] = []
        for (i, a) in live.enumerated() {
            for b in live.dropFirst(i + 1) {
                if a.linkKey == b.linkKey, a.kissPort == b.kissPort {
                    found.append(.duplicateLink(a.id, b.id))
                }
                let callA = a.resolvedCallsign(station: stationCallsign)
                if !callA.isEmpty, callA == b.resolvedCallsign(station: stationCallsign) {
                    found.append(.duplicateCallsign(a.id, b.id, callA))
                }
            }
        }
        return found
    }
}
