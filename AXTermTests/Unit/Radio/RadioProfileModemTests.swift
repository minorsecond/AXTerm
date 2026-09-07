import XCTest
@testable import AXTerm

/// A `.modem` radio is the built-in sound modem: audio devices instead of
/// a TNC address, a CI-V port for the radio itself. These pin how such a
/// profile keys, signs, names and describes itself, and which pairs of
/// radios cannot coexist.
final class RadioProfileModemTests: XCTestCase {

    private func modem(_ id: String = "705", input: String = "AppleUSBAudioEngine:CODEC:in",
                       output: String = "AppleUSBAudioEngine:CODEC:out", civ: String = "/dev/cu.usbmodem14201") -> RadioProfile {
        var radio = RadioProfile(id: RadioID(rawValue: id), name: id)
        radio.kind = .modem
        radio.audioInputDeviceUID = input
        radio.audioInputDeviceName = "USB Audio CODEC"
        radio.audioOutputDeviceUID = output
        radio.audioOutputDeviceName = "USB Audio CODEC"
        radio.civSerialPath = civ
        return radio
    }

    // MARK: - Decoding

    func testTheModemKindSpellsItself() {
        XCTAssertEqual(RadioTransportKind.modem.rawValue, "modem")
    }

    /// A profile written before the modem existed decodes with the modem
    /// defaults: 1200 bd, CI-V A4/E0, CI-V PTT, Direwolf-like timing.
    func testAnOlderProfileDecodesWithModemDefaults() throws {
        let minimal = Data(#"[{"id":"abc","name":"Base","kind":"modem"}]"#.utf8)
        let radio = try JSONDecoder().decode([RadioProfile].self, from: minimal)[0]
        XCTAssertEqual(radio.kind, .modem)
        XCTAssertEqual(radio.modemMode, .afsk1200)
        XCTAssertEqual(radio.audioInputDeviceUID, "")
        XCTAssertEqual(radio.audioInputChannel, .left)
        XCTAssertEqual(radio.civAddress, 0xA4)
        XCTAssertEqual(radio.civControllerAddress, 0xE0)
        XCTAssertEqual(radio.pttMethod, .civ)
        XCTAssertEqual(radio.txDelayMs, 300)
        XCTAssertEqual(radio.txTailMs, 100)
        XCTAssertEqual(radio.persistence, 63)
        XCTAssertEqual(radio.slotTimeMs, 100)
        XCTAssertEqual(radio.txAudioLevel, 85)
        XCTAssertTrue(radio.followsRadioFrequency)
        XCTAssertFalse(radio.setsRadioModeOnConnect)
        XCTAssertEqual(radio.maxTransmitSeconds, 30)
        XCTAssertEqual(radio.rigModel, "")
    }

    func testAModemProfileSurvivesJSON() throws {
        var radio = modem()
        radio.modemMode = .afsk300
        radio.pttMethod = .rts
        radio.audioInputChannel = .right
        radio.txAudioLevel = 40
        radio.rigModel = "IC-705"
        radio.frequencyHz = 7_074_500
        let data = try JSONEncoder().encode([radio])
        XCTAssertEqual(try JSONDecoder().decode([RadioProfile].self, from: data), [radio])
    }

    // MARK: - Keys and signatures

    /// The audio pair is the byte stream. The CI-V port is not part of the
    /// key: two modems on one sound device fight over it whatever their
    /// ports.
    func testTheLinkKeyIsTheAudioPairAndIgnoresTheCIVPort() {
        let a = modem("a")
        let b = modem("b", civ: "/dev/cu.usbmodem99")
        XCTAssertEqual(a.linkKey, "modem://appleusbaudioengine:codec:in|appleusbaudioengine:codec:out")
        XCTAssertEqual(a.linkKey, b.linkKey)
        XCTAssertNotEqual(a.linkKey, modem("c", output: "other").linkKey)
    }

    /// Devices, mode, CI-V port, keying and input channel reopen the link;
    /// levels, timing and the radio's frequency do not.
    func testTheSignatureMovesOnlyForWhatReopensTheLink() {
        let base = modem()
        var same = base
        same.txAudioLevel = 10
        same.txDelayMs = 500
        same.persistence = 128
        same.frequencyHz = 144_390_000
        same.rigModel = "IC-705"
        same.followsRadioFrequency = false
        XCTAssertEqual(same.transportSignature, base.transportSignature)

        var mode = base; mode.modemMode = .afsk300
        var civ = base; civ.civSerialPath = "/dev/cu.other"
        var ptt = base; ptt.pttMethod = .dtr
        var channel = base; channel.audioInputChannel = .mono
        var port = base; port.kissPort = 1
        for changed in [mode, civ, ptt, channel, port] {
            XCTAssertNotEqual(changed.transportSignature, base.transportSignature)
        }
    }

    // MARK: - Names

    func testDisplayEndpointAndDefaultName() {
        var radio = modem()
        XCTAssertEqual(radio.displayEndpoint, "Sound modem via USB Audio CODEC")
        XCTAssertEqual(RadioProfile.defaultName(for: radio), "Sound Modem")
        radio.rigModel = "IC-705"
        XCTAssertEqual(radio.displayEndpoint, "IC-705 via USB Audio CODEC")
        XCTAssertEqual(RadioProfile.defaultName(for: radio), "IC-705")

        var bare = RadioProfile(id: RadioID(rawValue: "x"), name: "x")
        bare.kind = .modem
        XCTAssertEqual(bare.displayEndpoint, "No audio device")
    }

    // MARK: - The link's view of the profile

    func testModemConfigMirrorsTheProfile() {
        var radio = modem()
        radio.modemMode = .afsk300
        radio.kissPort = 2
        radio.txAudioLevel = 100
        radio.persistence = 300 // out of range, clamps to a byte
        radio.pttMethod = .none
        let config = radio.modemConfig!
        XCTAssertEqual(config.mode, .afsk300)
        XCTAssertEqual(config.kissPort, 2)
        XCTAssertEqual(config.audioInputDeviceUID, radio.audioInputDeviceUID)
        XCTAssertEqual(config.civSerialPath, radio.civSerialPath)
        XCTAssertEqual(config.pttMethod, .none)
        XCTAssertEqual(config.persistence, 255)
        XCTAssertEqual(config.txLevelDBFS, 0, accuracy: 0.001)
        XCTAssertTrue(config.usesRig)

        var tcp = radio; tcp.kind = .tcp
        XCTAssertNil(tcp.modemConfig)
    }

    func testTxAudioLevelMapsToDBFS() {
        var config = ModemLinkConfig()
        config.txAudioLevel = 85
        XCTAssertEqual(config.txLevelDBFS, -6, accuracy: 0.001)
        config.txAudioLevel = 0
        XCTAssertEqual(config.txLevelDBFS, -40, accuracy: 0.001)
        config.txAudioLevel = 250
        XCTAssertEqual(config.txLevelDBFS, 0, accuracy: 0.001)
    }

    func testTheSoftModemConfigurationCarriesTimingAndWatchdog() {
        var config = ModemLinkConfig()
        config.txDelayMs = 250
        config.txTailMs = 60
        config.slotTimeMs = 50
        config.persistence = 100
        config.maxTransmitSeconds = 12
        let soft = config.softModemConfiguration
        XCTAssertEqual(soft.txDelayMs, 250)
        XCTAssertEqual(soft.txTailMs, 60)
        XCTAssertEqual(soft.slotTimeMs, 50)
        XCTAssertEqual(soft.persist, 100)
        XCTAssertEqual(soft.pttWatchdogSeconds, 12)
    }

    // MARK: - Radios that cannot both be

    func testTwoModemsOnOneSoundDeviceAreFlagged() {
        let a = modem("a")
        let b = modem("b", civ: "/dev/cu.other")
        let issues = RadioProfileIssue.issues(in: [a, b], stationCallsign: "K0EPI")
        XCTAssertTrue(issues.contains { if case .duplicateLink = $0 { return true }; return false },
                      "same pair, same port: the byte stream is one")
    }

    func testAModemSharingOnlyOneDeviceWithAnotherIsFlagged() {
        let a = modem("a")
        let b = modem("b", output: "some-other-output", civ: "/dev/cu.other")
        let issues = RadioProfileIssue.issues(in: [a, b], stationCallsign: "K0EPI")
        XCTAssertTrue(issues.contains { if case .duplicateAudioDevice = $0 { return true }; return false })
        XCTAssertFalse(issues.contains { if case .duplicateLink = $0 { return true }; return false })
    }

    func testAModemOnASerialTNCsPortIsFlagged() {
        var m = modem("m")
        m.callsign = "K0EPI-1"
        var serial = RadioProfile(id: RadioID(rawValue: "s"), name: "s")
        serial.kind = .serial
        serial.callsign = "K0EPI-2"
        serial.serialDevicePath = m.civSerialPath
        let issues = RadioProfileIssue.issues(in: [m, serial], stationCallsign: "K0EPI")
        XCTAssertTrue(issues.contains { if case .duplicateSerialPort = $0 { return true }; return false })

        serial.serialDevicePath = "/dev/cu.elsewhere"
        XCTAssertTrue(RadioProfileIssue.issues(in: [m, serial], stationCallsign: "K0EPI").isEmpty)
    }

    func testAModemAndADirewolfCoexist() {
        var direwolf = RadioProfile(id: RadioID(rawValue: "d"), name: "d")
        direwolf.kind = .tcp
        direwolf.host = "192.168.3.218"
        direwolf.port = 8001
        direwolf.callsign = "K0EPI-7"
        var m = modem()
        m.callsign = "K0EPI-5"
        XCTAssertTrue(RadioProfileIssue.issues(in: [m, direwolf], stationCallsign: "K0EPI").isEmpty)
    }
}
