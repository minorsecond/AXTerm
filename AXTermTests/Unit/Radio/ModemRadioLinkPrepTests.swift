#if os(macOS)
import XCTest
@testable import AXTerm

/// A sound-modem radio through a whole session with "Set up the radio for
/// packet while connected" on: connect and prepare, a setting changed by
/// hand and fixed, then close and put back, with every CI-V frame checked in
/// order against a radio that remembers its settings.
///
/// Until 2026-09-30 AXTerm wrote the radio at connect and never undid it.
final class ModemRadioLinkPrepTests: XCTestCase {

    private nonisolated final class Spy: KISSLinkDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [KISSLinkState] = []
        private var _notices: [String] = []
        private var _reports: [RigReceiveAudit.Report] = []
        var states: [KISSLinkState] { lock.withLock { _states } }
        var notices: [String] { lock.withLock { _notices } }
        var reports: [RigReceiveAudit.Report] { lock.withLock { _reports } }
        func linkDidReceive(_ data: Data) {}
        func linkDidChangeState(_ state: KISSLinkState) { lock.withLock { _states.append(state) } }
        func linkDidError(_ message: String) { lock.withLock { _notices.append(message) } }
        func report(_ r: RigReceiveAudit.Report) { lock.withLock { _reports.append(r) } }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let radioID = RadioID(rawValue: "prep-test-radio")

    override func setUp() {
        super.setUp()
        suiteName = "ModemRadioLinkPrepTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var store: RigPrepStore { RigPrepStore(defaults: defaults) }

    private func config(prepares: Bool = true, follows: Bool = false, mode: ModemMode = .afsk1200) -> ModemLinkConfig {
        var c = ModemLinkConfig()
        c.audioInputDeviceUID = "in"; c.audioInputDeviceName = "USB Audio CODEC"
        c.audioOutputDeviceUID = "out"; c.audioOutputDeviceName = "USB Audio CODEC"
        c.civSerialPath = "/dev/cu.usbmodem14201"
        c.pttMethod = .civ
        c.mode = mode
        c.setsRadioModeOnConnect = prepares
        c.followsRadioFrequency = follows
        c.radioID = radioID
        return c
    }

    private func makeLink(_ config: ModemLinkConfig, radio: FakeIcomRadio) -> (ModemRadioLink, FakeCIVTransport, Spy) {
        let transport = FakeCIVTransport()
        transport.replyDelay = 0
        transport.responder = radio.responder
        let link = ModemRadioLink(config: config, audio: SyntheticModemIO(), makeTransport: { _ in transport },
                                  scheduling: .inline, prepStore: store)
        let spy = Spy()
        link.delegate = spy
        link.onRigReceive = { [spy] report in spy.report(report) }
        return (link, transport, spy)
    }

    @discardableResult
    private func waitUntil(_ what: String, timeout: TimeInterval = 3,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        let met = condition()
        if !met { XCTFail("timed out after \(timeout)s waiting for: \(what)", file: file, line: line) }
        return met
    }

    private func connect(_ link: ModemRadioLink, _ spy: Spy) async {
        let reportsBefore = spy.reports.count
        link.open()
        await waitUntil("the link to connect") { link.state == .connected }
        // The first audit after connecting is the drift watch's baseline.
        await waitUntil("the baseline audit") { spy.reports.count > reportsBefore }
    }

    private func closeAndWait(_ link: ModemRadioLink) async {
        link.close()
        await waitUntil("the close to finish") { !link.isClosingRig }
    }

    private nonisolated func hex(_ frame: CIVFrame) -> String {
        frame.encoded().map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Writes only. A read of `1A 05` carries the two item bytes and nothing
    /// else; every other read carries no data at all.
    private nonisolated func isWrite(_ frame: CIVFrame) -> Bool {
        if frame.command == 0x1A, frame.subcommand == 0x05 { return frame.data.count > 2 }
        return !frame.data.isEmpty
    }

    // MARK: - The whole session

    func testConnectPrepareDriftFixCloseRestore() async throws {
        let radio = FakeIcomRadio()
        let original = radio.snapshot
        let (link, transport, spy) = makeLink(config(), radio: radio)

        // Connect: identify first, then exactly the writes the packet setup
        // needs, in order.
        await connect(link, spy)
        let connectFrames = transport.written.map(hex)
        XCTAssertEqual(connectFrames.first, "FE FE A4 E0 19 00 FD", "who are you")
        XCTAssertEqual(transport.written.filter(isWrite).map(hex), [
            "FE FE A4 E0 06 05 01 FD",              // FM, FIL1
            "FE FE A4 E0 1A 06 01 01 FD",           // data mode on
            "FE FE A4 E0 1A 05 01 19 01 FD",        // DATA MOD = USB
            "FE FE A4 E0 1A 05 01 11 00 FD",        // USB AF squelch open
            "FE FE A4 E0 1A 05 01 25 00 FD",        // USB SEND off
            "FE FE A4 E0 1A 05 01 31 00 FD",        // CI-V transceive off
            "FE FE A4 E0 1A 05 01 31 00 FD",        // ...and the transceive command itself
            "FE FE A4 E0 1A 05 00 38 00 FD",        // TX delays off
            "FE FE A4 E0 1A 05 00 39 00 FD",
            "FE FE A4 E0 1A 05 00 41 00 FD",
            "FE FE A4 E0 1A 05 00 42 00 FD",
            "FE FE A4 E0 11 00 FD",                 // attenuator off
            "FE FE A4 E0 14 02 02 55 FD",           // RF gain full
            "FE FE A4 E0 14 03 00 00 FD",           // squelch open
            "FE FE A4 E0 16 40 00 FD",              // NR off
            "FE FE A4 E0 16 41 00 FD",              // auto notch off
            "FE FE A4 E0 16 5D 01 FD",              // TSQL to TONE, transmit tone kept
        ])
        XCTAssertEqual(radio["1602"], [0x01], "the preamp is the operator's")
        let stored = try XCTUnwrap(store.load(radioID), "stored as soon as it was changed")
        XCTAssertEqual(stored.entry(for: .mode)?.original, [0x01, 0x02, 0x00, 0x00])
        XCTAssertEqual(stored.entry(for: .toneSquelch)?.original, [0x02])
        XCTAssertTrue(spy.notices.contains { $0.contains("AXTerm puts these back when you disconnect or quit") },
                      spy.notices.joined(separator: " | "))

        // Drift: the operator turns the manual notch on by hand.
        radio["1648"] = [0x01]
        await link.watchForReceiveDrift()
        XCTAssertEqual(link.receiveReport.drift.map(\.title), ["The manual notch is on"])
        XCTAssertEqual(spy.reports.last?.drift.map(\.title), ["The manual notch is on"])
        await waitUntil("the drift notice") { spy.notices.contains { $0.contains("The radio changed under us") } }
        XCTAssertEqual(radio["1648"], [0x01], "told, not silently reverted")

        // A second audit does not announce it again.
        let noticesBefore = spy.notices.count
        await link.watchForReceiveDrift()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(spy.notices.count, noticesBefore, "announced once")

        // Fix: one click, and the fix joins the snapshot.
        let beforeFix = transport.written.count
        let done = await link.fixReceiveDrift()
        XCTAssertEqual(done, ["The manual notch is on"])
        XCTAssertEqual(transport.written.dropFirst(beforeFix).filter(isWrite).map(hex), ["FE FE A4 E0 16 48 00 FD"])
        XCTAssertEqual(radio["1648"], [0x00])
        XCTAssertTrue(link.receiveReport.drift.isEmpty)
        XCTAssertEqual(store.load(radioID)?.entry(for: .manualNotch),
                       .init(setting: .manualNotch, original: [0x01], applied: [0x00]))

        // The operator nudges the squelch during the session: theirs now.
        radio["1403"] = [0x00, 0x20]

        // Close: PTT off first, then the reads, then the originals in reverse.
        let snapshot = try XCTUnwrap(store.load(radioID))
        let beforeClose = transport.written.count
        await closeAndWait(link)
        let closing = Array(transport.written.dropFirst(beforeClose))
        XCTAssertEqual(closing.first.map(hex), "FE FE A4 E0 1C 00 00 FD", "PTT off before anything else")
        let expectedWrites = snapshot.entries.reversed()
            .filter { $0.setting != .squelch }
            .flatMap { $0.setting.writeFrames($0.original, radio: 0xA4, controller: 0xE0) }
            .map(hex)
        XCTAssertEqual(closing.dropFirst().filter(isWrite).map(hex), expectedWrites)

        var expectedRadio = original
        expectedRadio["1403"] = [0x00, 0x20]
        // The fix joined the snapshot, so the manual notch goes back on: it
        // is how the operator had it when they pressed Fix. The session's
        // fix is for the session.
        expectedRadio["1648"] = [0x01]
        XCTAssertEqual(radio.snapshot, expectedRadio, "everything back but the squelch the operator set")
        XCTAssertNil(store.load(radioID), "nothing owed")
        await waitUntil("the restore notice") { spy.notices.contains { $0.contains("Put the radio back as it was") } }
        XCTAssertTrue(spy.notices.contains { $0.contains("Left squelch as you set it") }, spy.notices.joined(separator: " | "))
    }

    // MARK: - Reconnects and crashes

    /// A sleep, or any reconnect, finds the radio already prepared. The
    /// snapshot keeps the operator's originals and gains nothing.
    func testAReconnectThatFindsTheRadioPreparedKeepsTheOriginals() async throws {
        let radio = FakeIcomRadio()
        let original = radio.snapshot
        let (link, transport, spy) = makeLink(config(), radio: radio)
        await connect(link, spy)
        let first = try XCTUnwrap(store.load(radioID))

        link.suspend()
        await waitUntil("the suspend to finish") { !link.isClosingRig }
        XCTAssertEqual(store.load(radioID), first, "a pause restores nothing and loses nothing")
        XCTAssertEqual(radio["1641"], [0x00], "still prepared")

        let beforeReconnect = transport.written.count
        await connect(link, spy)
        XCTAssertFalse(transport.written.dropFirst(beforeReconnect).contains { $0.command == 0x06 },
                       "already right, so not rewritten")
        XCTAssertEqual(store.load(radioID), first, "AXTerm's own values were not taken for the operator's")

        await closeAndWait(link)
        XCTAssertEqual(radio.snapshot, original)
        XCTAssertNil(store.load(radioID))
    }

    /// The last session crashed before it could restore. Its snapshot is
    /// still stored and the radio is still prepared; the next session puts
    /// back the originals from before the crash.
    func testAStoredSnapshotFromACrashKeepsItsOriginals() async {
        let radio = FakeIcomRadio(FakeIcomRadio.packetSetup())
        store.save(RigPrepSnapshot(entries: [
            .init(setting: .mode, original: [0x01, 0x02, 0x00, 0x00], applied: [0x05, 0x01, 0x01, 0x01]),
            .init(setting: .autoNotch, original: [0x01], applied: [0x00]),
            .init(setting: .menuItem(119), original: [0x00], applied: [0x01]),
        ]), for: radioID)
        let (link, _, spy) = makeLink(config(), radio: radio)
        await connect(link, spy)
        XCTAssertEqual(store.load(radioID)?.entry(for: .autoNotch)?.original, [0x01],
                       "the crash's original survives the reconnect")
        XCTAssertEqual(store.load(radioID)?.entries.count, 3, "nothing new was changed, so nothing new is owed")

        await closeAndWait(link)
        XCTAssertEqual(radio["04"], [0x01, 0x02])
        XCTAssertEqual(radio["1A06"], [0x00, 0x00])
        XCTAssertEqual(radio["1641"], [0x01])
        XCTAssertEqual(radio["1A05:0119"], [0x00])
        XCTAssertNil(store.load(radioID))
    }

    /// A reconnect started before the last close finished waits for it:
    /// the restore runs to the end, then the new connect prepares again
    /// from the operator's settings.
    func testASecondConnectWaitsForTheRestore() async throws {
        let radio = FakeIcomRadio()
        let (link, transport, spy) = makeLink(config(), radio: radio)
        await connect(link, spy)
        let snapshot = try XCTUnwrap(store.load(radioID))

        let beforeClose = transport.written.count
        link.close()
        link.open()
        await waitUntil("the link to reconnect") { link.state == .connected }
        let frames = Array(transport.written.dropFirst(beforeClose))
        let restoreEnd = try XCTUnwrap(frames.lastIndex { self.hex($0) == "FE FE A4 E0 1A 06 00 00 FD" },
                                       "the mode restore's data-off write")
        let identify = try XCTUnwrap(frames.firstIndex { self.hex($0) == "FE FE A4 E0 19 00 FD" })
        XCTAssertLessThan(restoreEnd, identify, "the whole restore went out before the reconnect began")
        XCTAssertEqual(store.load(radioID)?.entry(for: .mode)?.original, snapshot.entry(for: .mode)?.original)
        XCTAssertEqual(radio["1641"], [0x00], "prepared again")
        await closeAndWait(link)
    }

    /// A radio that drops off the link is not a disconnect: nothing is put
    /// back, and the snapshot waits.
    func testALostRadioRestoresNothing() async throws {
        let radio = FakeIcomRadio()
        let (link, transport, spy) = makeLink(config(), radio: radio)
        await connect(link, spy)
        let snapshot = try XCTUnwrap(store.load(radioID))
        let before = transport.written.count
        transport.fail("the port went away")
        await waitUntil("the link to fail") { link.state == .failed }
        XCTAssertFalse(transport.written.dropFirst(before).contains(where: isWrite), "nothing written")
        XCTAssertEqual(store.load(radioID), snapshot)
        await closeAndWait(link)
        XCTAssertEqual(store.load(radioID), snapshot, "a close with the port gone keeps what is owed")
    }

    /// A reopen for a settings change (here the modem mode) is not a
    /// disconnect either. The new setup's mode change keeps the original.
    func testAReopenForASettingsChangeRestoresNothing() async throws {
        let radio = FakeIcomRadio()
        let (link, _, spy) = makeLink(config(), radio: radio)
        await connect(link, spy)
        link.updateConfig(config(mode: .afsk300))
        await waitUntil("the link to reconnect in the new mode") {
            link.state == .connected && radio["04"] == [0x01, 0x01]
        }
        XCTAssertEqual(radio["1641"], [0x00], "not put back in between")
        let mode = try XCTUnwrap(store.load(radioID)?.entry(for: .mode))
        XCTAssertEqual(mode.original, [0x01, 0x02, 0x00, 0x00], "still the operator's USB on FIL2")
        XCTAssertEqual(mode.applied, [0x01, 0x01, 0x01, 0x01])
        await closeAndWait(link)
        XCTAssertEqual(radio["04"], [0x01, 0x02])
        XCTAssertEqual(radio["1A06"], [0x00, 0x00])
    }

    // MARK: - The switch

    func testSwitchingOffWhileConnectedRestoresNow() async {
        let radio = FakeIcomRadio()
        let original = radio.snapshot
        let (link, _, spy) = makeLink(config(), radio: radio)
        await connect(link, spy)
        link.updateConfig(config(prepares: false))
        await waitUntil("the restore") { self.store.load(self.radioID) == nil }
        XCTAssertEqual(radio.snapshot, original)
        XCTAssertEqual(link.state, .connected, "still connected")
        await closeAndWait(link)
    }

    func testSwitchingOnWhileConnectedPreparesNow() async {
        let radio = FakeIcomRadio()
        let (link, _, spy) = makeLink(config(prepares: false), radio: radio)
        await connect(link, spy)
        XCTAssertEqual(radio["1641"], [0x01], "left alone while off")
        link.updateConfig(config(prepares: true))
        await waitUntil("the setup") { radio["1641"] == [0x00] }
        await waitUntil("the record") { self.store.load(self.radioID)?.entry(for: .autoNotch) != nil }
        await closeAndWait(link)
        XCTAssertEqual(radio["1641"], [0x01])
    }

    /// With the switch off AXTerm neither prepares nor records nor restores.
    func testWithTheSwitchOffTheRadioIsLeftAlone() async {
        let radio = FakeIcomRadio()
        let original = radio.snapshot
        let (link, transport, spy) = makeLink(config(prepares: false), radio: radio)
        await connect(link, spy)
        await closeAndWait(link)
        XCTAssertEqual(radio.snapshot, original)
        XCTAssertNil(store.load(radioID))
        XCTAssertEqual(transport.written.filter(isWrite).map(hex), ["FE FE A4 E0 1C 00 00 FD"], "only PTT off")
    }

    /// A fix made with the switch off is the operator's own change and is
    /// not recorded for putting back.
    func testAFixWithTheSwitchOffIsNotRecorded() async {
        let radio = FakeIcomRadio()
        let (link, _, spy) = makeLink(config(prepares: false), radio: radio)
        await connect(link, spy)
        radio["1648"] = [0x01]
        await link.watchForReceiveDrift()
        _ = await link.fixReceiveDrift()
        XCTAssertEqual(radio["1648"], [0x00])
        XCTAssertNil(store.load(radioID))
        await closeAndWait(link)
        XCTAssertEqual(radio["1648"], [0x00], "not put back")
    }

    /// The receive audit no longer depends on following the frequency.
    func testTheDriftWatchWorksWithoutFollowingTheFrequency() async {
        let radio = FakeIcomRadio(FakeIcomRadio.packetSetup())
        let (link, _, spy) = makeLink(config(prepares: false, follows: false), radio: radio)
        await connect(link, spy)
        radio["1641"] = [0x01]
        await link.watchForReceiveDrift()
        XCTAssertEqual(link.receiveReport.drift.map(\.title), ["The auto notch is on"])
        await closeAndWait(link)
    }

    /// The quit path waits on this flag; it must be up from the moment
    /// `close()` returns until the port has shut.
    func testClosingIsVisibleUntilTheRestoreFinishes() async {
        let radio = FakeIcomRadio()
        let (link, _, spy) = makeLink(config(), radio: radio)
        await connect(link, spy)
        XCTAssertTrue(link.hasPreparedRadio)
        link.close()
        XCTAssertTrue(link.isClosingRig, "set synchronously by close()")
        await waitUntil("the close to finish") { !link.isClosingRig }
        XCTAssertFalse(link.hasPreparedRadio)
    }

    /// Two links for two radios keep their snapshots apart.
    func testTwoRadiosKeepSeparateSnapshots() async {
        let radioA = FakeIcomRadio(), radioB = FakeIcomRadio(FakeIcomRadio.packetSetup())
        radioB["1640"] = [0x01]
        let (linkA, _, spyA) = makeLink(config(), radio: radioA)
        var configB = config()
        configB.radioID = RadioID(rawValue: "prep-test-radio-b")
        let (linkB, _, spyB) = makeLink(configB, radio: radioB)
        await connect(linkA, spyA)
        await connect(linkB, spyB)
        XCTAssertEqual(store.load(RadioID(rawValue: "prep-test-radio-b"))?.settings, [.noiseReduction])
        XCTAssertGreaterThan(store.load(radioID)?.entries.count ?? 0, 1)
        await closeAndWait(linkB)
        XCTAssertNil(store.load(RadioID(rawValue: "prep-test-radio-b")))
        XCTAssertNotNil(store.load(radioID), "closing B leaves A owed")
        await closeAndWait(linkA)
    }
}
#endif
