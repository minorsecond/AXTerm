import XCTest
@testable import AXTerm

/// The radio form's sound-modem half: the fields are the profile, edits go
/// back to it, and the buttons do what their labels say — or say why not.
@MainActor
final class ConnectionTransportViewModelModemTests: XCTestCase {

    private var defaults: UserDefaults!
    private var settings: AppSettingsStore!
    private var engine: PacketEngine!
    private var radioID: RadioID!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "ConnectionTransportViewModelModemTests.\(UUID().uuidString)")!
        settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "K0EPI"
        engine = PacketEngine(settings: settings)
        // Off, so nothing tries to open sound devices in a test process.
        let radio = settings.addRadio()
        radioID = radio.id
        settings.updateRadio(radio.id) {
            $0.kind = .modem
            $0.enabled = false
            $0.callsign = "K0EPI-5"
            $0.audioInputDeviceUID = "in-uid"
            $0.audioInputDeviceName = "USB Audio CODEC"
            $0.audioOutputDeviceUID = "out-uid"
            $0.audioOutputDeviceName = "USB Audio CODEC"
            $0.civSerialPath = "/dev/cu.usbmodem14201"
            $0.modemMode = .afsk300
            $0.pttMethod = .dtr
            $0.txDelayMs = 250
            $0.txAudioLevel = 40
            $0.civAddress = 0x94
            $0.rigModel = "IC-7300"
        }
    }

    private func makeViewModel() -> ConnectionTransportViewModel {
        ConnectionTransportViewModel(radioID: radioID, settings: settings, packetEngine: engine)
    }

    private var profile: RadioProfile { settings.radio(radioID)! }

    // MARK: - Profile <-> fields

    func testTheFieldsAreTheProfile() async {
        let vm = makeViewModel()
        XCTAssertEqual(vm.selectedTransport, .modem)
        XCTAssertTrue(vm.isModemTransport)
        XCTAssertEqual(vm.modemMode, .afsk300)
        XCTAssertEqual(vm.audioInputDeviceUID, "in-uid")
        XCTAssertEqual(vm.audioOutputDeviceUID, "out-uid")
        XCTAssertEqual(vm.civSerialPath, "/dev/cu.usbmodem14201")
        XCTAssertEqual(vm.civAddressHex, "94")
        XCTAssertEqual(vm.pttMethod, .dtr)
        XCTAssertEqual(vm.txDelayMs, 250)
        XCTAssertEqual(vm.txAudioLevel, 40)
        XCTAssertEqual(vm.rigModel, "IC-7300")
        XCTAssertTrue(vm.followsRadioFrequency)
        XCTAssertFalse(vm.setsRadioModeOnConnect)
    }

    func testEditsWriteTheProfile() async {
        let vm = makeViewModel()
        vm.modemMode = .afsk1200
        vm.txDelayMs = 400
        vm.txTailMs = 80
        vm.persistence = 128
        vm.slotTimeMs = 50
        vm.txAudioLevel = 70.4
        vm.pttMethod = .rts
        vm.civSerialPath = "/dev/cu.other"
        vm.followsRadioFrequency = false
        vm.setsRadioModeOnConnect = true
        vm.maxTransmitSeconds = 10
        vm.audioInputChannel = .mono

        XCTAssertEqual(profile.modemMode, .afsk1200)
        XCTAssertEqual(profile.txDelayMs, 400)
        XCTAssertEqual(profile.txTailMs, 80)
        XCTAssertEqual(profile.persistence, 128)
        XCTAssertEqual(profile.slotTimeMs, 50)
        XCTAssertEqual(profile.txAudioLevel, 70, "the profile keeps it whole")
        XCTAssertEqual(profile.pttMethod, .rts)
        XCTAssertEqual(profile.civSerialPath, "/dev/cu.other")
        XCTAssertFalse(profile.followsRadioFrequency)
        XCTAssertTrue(profile.setsRadioModeOnConnect)
        XCTAssertEqual(profile.maxTransmitSeconds, 10)
        XCTAssertEqual(profile.audioInputChannel, .mono)
    }

    func testOutOfRangeTimingIsClamped() async {
        let vm = makeViewModel()
        vm.persistence = 900
        vm.maxTransmitSeconds = 1
        vm.slotTimeMs = 0
        XCTAssertEqual(profile.persistence, 255)
        XCTAssertEqual(profile.maxTransmitSeconds, 3)
        XCTAssertEqual(profile.slotTimeMs, 10)
    }

    func testTheCIVAddressIsHexAndBadHexChangesNothing() async {
        let vm = makeViewModel()
        vm.civAddressHex = "a4"
        XCTAssertEqual(profile.civAddress, 0xA4)
        vm.civAddressHex = "ZZ"
        XCTAssertEqual(profile.civAddress, 0xA4, "half-typed text is not an address")
        vm.civAddressHex = ""
        XCTAssertEqual(profile.civAddress, 0xA4)
    }

    /// The audio pair is the link key, so a device choice writes the UID
    /// and its name together.
    func testChoosingAnAudioDeviceWritesUIDAndName() async {
        let vm = makeViewModel()
        vm.userDidChangeAudioInput("new-in")
        XCTAssertEqual(vm.audioInputDeviceUID, "new-in")
        XCTAssertEqual(profile.audioInputDeviceUID, "new-in")
        XCTAssertEqual(profile.audioInputDeviceName, "", "a device the Mac does not list has no name to give")
        vm.userDidChangeAudioOutput("")
        XCTAssertEqual(profile.audioOutputDeviceUID, "")
        XCTAssertEqual(profile.audioOutputDeviceName, "")
    }

    // MARK: - Transport switch

    func testSwitchingARadioToTheModemSetsItsKindAndCapabilities() async {
        settings.updateRadio(radioID) { $0.kind = .tcp; $0.capabilities = TNCCapabilities() }
        let vm = makeViewModel()
        XCTAssertEqual(vm.selectedTransport, .network)
        vm.userDidChangeTransport(.modem)
        for _ in 0..<50 where profile.kind != .modem {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(profile.kind, .modem)
        XCTAssertTrue(profile.capabilities.supportsModemTuning, "our own modem tunes itself")
        XCTAssertTrue(profile.capabilities.supportsLinkTuning)
    }

    func testTheSegmentIsOfferedWhereTheModemCanRun() {
        #if os(macOS)
        XCTAssertTrue(TransportSelection.selectable(including: .network).contains(.modem))
        #else
        XCTAssertFalse(TransportSelection.selectable(including: .network).contains(.modem))
        XCTAssertTrue(TransportSelection.selectable(including: .modem).contains(.modem), "a modem profile can still be seen and changed")
        #endif
        XCTAssertEqual(TransportSelection.modem.rawValue, "Sound Modem")
    }

    // MARK: - Actions

    func testTheTestFrameIsAUIFrameToTESTFromTheRadiosCallsign() async {
        let vm = makeViewModel()
        let frame = vm.sendTestFrame()
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.destination, AX25Address(call: "TEST"))
        XCTAssertEqual(frame?.source, AX25Address(call: "K0EPI", ssid: 5))
        XCTAssertEqual(frame?.radio, radioID)
        XCTAssertEqual(frame?.frameType, "ui")
        XCTAssertEqual(frame?.pid, 0xF0)
        XCTAssertTrue(String(decoding: frame!.payload, as: UTF8.self).hasPrefix("AXTerm sound modem test"))
        // The radio is not connected, and the form says so.
        for _ in 0..<50 where vm.modemActionMessage == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.modemActionMessage?.hasPrefix("Not sent"), true)
    }

    func testTheTestFrameFallsBackToTheStationCallsign() async {
        settings.updateRadio(radioID) { $0.callsign = "" }
        let vm = makeViewModel()
        XCTAssertEqual(vm.sendTestFrame()?.source, AX25Address(call: "K0EPI", ssid: 0))
        settings.myCallsign = ""
        XCTAssertNil(vm.sendTestFrame())
        XCTAssertEqual(vm.modemActionMessage, "Set a callsign first.")
    }

    func testToneAndSetupNeedAConnectedRadio() async {
        let vm = makeViewModel()
        #if os(macOS)
        let expected = "Connect the radio first."
        #else
        let expected = "The sound modem needs a Mac."
        #endif
        vm.sendTestTone()
        XCTAssertEqual(vm.modemActionMessage, expected)
        XCTAssertFalse(vm.isSendingTestTone)
        vm.configureRadioForPacket()
        XCTAssertEqual(vm.modemActionMessage, expected)
    }

    func testTheSetupSheetSaysExactlyWhatIsPushed() {
        let fm = ModemRadioSection.setupDescription(for: .afsk1200)
        XCTAssertTrue(fm.contains("FM-D"))
        XCTAssertTrue(fm.contains("DATA MOD input: USB."))
        XCTAssertTrue(fm.contains("USB SEND: OFF"))
        XCTAssertTrue(fm.contains("The frequency is not touched."))
        let ssb = ModemRadioSection.setupDescription(for: .afsk300)
        XCTAssertTrue(ssb.contains("USB-D"))
        XCTAssertFalse(ssb.contains("FM-D"))
    }

    /// The advice has to name the modulation source the link actually uses.
    ///
    /// `configureForPacket` sends DATA MOD = WLAN over the radio's Wi-Fi and
    /// USB over a cable. The sheet and the note under the mode picker said
    /// USB either way, so a Wi-Fi operator following them set the radio to
    /// take modulation from a cable that is not there — it keys up and
    /// carries silence, which is indistinguishable from a dead antenna
    /// (2026-09-17).
    func testTheSetupAdviceFollowsTheLink() {
        let wifi = ModemRadioSection.setupDescription(for: .afsk1200, rigLink: .lan)
        XCTAssertTrue(wifi.contains("DATA MOD input: WLAN."), wifi)
        XCTAssertFalse(wifi.contains("DATA MOD input: USB."), wifi)

        let cable = ModemRadioSection.setupDescription(for: .afsk1200, rigLink: .usb)
        XCTAssertTrue(cable.contains("DATA MOD input: USB."), cable)

        XCTAssertTrue(ModemMode.afsk1200.radioSetupNote(rigLink: .lan).contains("DATA MOD set to WLAN"))
        XCTAssertTrue(ModemMode.afsk1200.radioSetupNote(rigLink: .usb).contains("DATA MOD set to USB"))
    }

    /// The value the radio actually wants for each link.
    ///
    /// From the IC-705 CI-V Reference Guide, set-mode item 0119 ("MOD Input
    /// > DATA MOD"): `00=MIC, 01=USB, 02=MIC, USB, 03=WLAN`. `wlan` was
    /// 0x02 — "MIC, USB" — so a Wi-Fi radio was told to modulate from the
    /// microphone and the USB port while the packet audio arrived over the
    /// network. It keyed up and transmitted the room, and nothing that heard
    /// it could decode a frame (2026-09-17).
    func testDataModCarriesTheRadiosOwnCodes() {
        XCTAssertEqual(CIVClient.DataModSource.mic.rawValue, 0x00)
        XCTAssertEqual(CIVClient.DataModSource.usb.rawValue, 0x01)
        XCTAssertEqual(CIVClient.DataModSource.micAndUSB.rawValue, 0x02)
        XCTAssertEqual(CIVClient.DataModSource.wlan.rawValue, 0x03,
                       "0x02 is the radio's \"MIC, USB\", which modulates from neither the "
                       + "network nor anything else carrying packet audio")
        XCTAssertNotEqual(CIVClient.DataModSource.wlan.rawValue,
                          CIVClient.DataModSource.micAndUSB.rawValue)
    }

    /// Nothing about the modem leaks into a TNC radio's form.
    func testATCPRadioHasNoModemState() async {
        settings.updateRadio(radioID) { $0.kind = .tcp }
        let vm = makeViewModel()
        XCTAssertFalse(vm.isModemTransport)
        XCTAssertNil(vm.modemTelemetry)
        XCTAssertNil(vm.rigStatus)
        XCTAssertNil(vm.identifyResult)
    }
}
