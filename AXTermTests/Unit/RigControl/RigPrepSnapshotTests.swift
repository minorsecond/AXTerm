import XCTest
@testable import AXTerm

/// What AXTerm owes back to a radio: how changes are recorded, how the
/// record survives a restart or a crash, and how one radio's record is kept
/// apart from another's.
final class RigPrepSnapshotTests: XCTestCase {

    private typealias Entry = RigPrepSnapshot.Entry

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = TestDefaults.name("RigPrepSnapshotTests")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let notchOn = Entry(setting: .autoNotch, original: [0x01], applied: [0x00])
    private let usbToFM = Entry(setting: .mode, original: [0x01, 0x02, 0x00, 0x00], applied: [0x05, 0x01, 0x01, 0x01])
    private let dataModMic = Entry(setting: .menuItem(119), original: [0x00], applied: [0x01])

    // MARK: - Recording

    func testAChangeIsRecordedInOrder() {
        var s = RigPrepSnapshot()
        s.record(usbToFM)
        s.record(dataModMic)
        s.record(notchOn)
        XCTAssertEqual(s.settings, [.mode, .menuItem(119), .autoNotch])
    }

    func testAWriteThatChangedNothingIsNotOwed() {
        var s = RigPrepSnapshot()
        s.record(Entry(setting: .autoNotch, original: [0x00], applied: [0x00]))
        XCTAssertTrue(s.isEmpty)
    }

    /// The case the snapshot exists for. After a crash the radio still holds
    /// AXTerm's settings; the next change to the same setting must keep the
    /// operator's original, not adopt AXTerm's value as one.
    func testASecondChangeKeepsTheFirstOriginal() {
        var s = RigPrepSnapshot()
        s.record(Entry(setting: .toneSquelch, original: [0x02], applied: [0x01]))
        s.record(Entry(setting: .toneSquelch, original: [0x01], applied: [0x00]))
        XCTAssertEqual(s.entry(for: .toneSquelch), Entry(setting: .toneSquelch, original: [0x02], applied: [0x00]))
        XCTAssertEqual(s.entries.count, 1, "one entry per setting")
    }

    func testAChangeBackToTheOriginalSettlesTheEntry() {
        var s = RigPrepSnapshot()
        s.record(notchOn)
        s.record(Entry(setting: .autoNotch, original: [0x00], applied: [0x01]))
        XCTAssertTrue(s.isEmpty, "the notch is back where the operator had it; nothing is owed")
    }

    func testAMergeKeepsItsPlaceInTheOrder() {
        var s = RigPrepSnapshot(entries: [usbToFM, notchOn, dataModMic])
        s.record(Entry(setting: .autoNotch, original: [0x00], applied: [0x00]))
        XCTAssertEqual(s.settings, [.mode, .autoNotch, .menuItem(119)])
    }

    func testMalformedEntriesAreNotRecorded() {
        var s = RigPrepSnapshot()
        s.record(Entry(setting: .autoNotch, original: [0x07], applied: [0x00]))
        s.record(Entry(setting: .mode, original: [0x01], applied: [0x05, 0x01, 0x01, 0x01]))
        XCTAssertTrue(s.isEmpty)
    }

    func testRemoving() {
        let s = RigPrepSnapshot(entries: [usbToFM, notchOn, dataModMic])
        XCTAssertEqual(s.removing([.autoNotch, .mode]).settings, [.menuItem(119)])
        XCTAssertEqual(s.removing([]).settings, s.settings)
    }

    // MARK: - Persistence

    func testRoundTrip() {
        let store = RigPrepStore(defaults: defaults)
        let radio = RadioID(rawValue: "radio-a")
        let s = RigPrepSnapshot(entries: [usbToFM, dataModMic, notchOn])
        store.save(s, for: radio)
        XCTAssertEqual(store.load(radio), s)
        XCTAssertNotNil(defaults.data(forKey: "rigPrep.v1.radio-a"), "the key the spec names")
    }

    func testNothingStoredLoadsAsNothing() {
        XCTAssertNil(RigPrepStore(defaults: defaults).load(RadioID(rawValue: "never")))
    }

    func testSavingAnEmptySnapshotForgetsTheRadio() {
        let store = RigPrepStore(defaults: defaults)
        let radio = RadioID(rawValue: "radio-a")
        store.save(RigPrepSnapshot(entries: [notchOn]), for: radio)
        store.save(RigPrepSnapshot(), for: radio)
        XCTAssertNil(store.load(radio))
        XCTAssertNil(defaults.object(forKey: RigPrepStore.key(radio)))
    }

    func testACorruptValueLoadsAsNothing() {
        let radio = RadioID(rawValue: "radio-a")
        defaults.set(Data("not json at all".utf8), forKey: RigPrepStore.key(radio))
        XCTAssertNil(RigPrepStore(defaults: defaults).load(radio))
        defaults.set("a string, not data", forKey: RigPrepStore.key(radio))
        XCTAssertNil(RigPrepStore(defaults: defaults).load(radio))
    }

    /// One damaged entry does not cost the rest: they are still owed.
    func testADamagedEntryIsDroppedAndTheRestKept() throws {
        let radio = RadioID(rawValue: "radio-a")
        let json = """
        {"entries":[
          {"setting":"autoNotch","original":[1],"applied":[0]},
          {"setting":"vsc","original":[1],"applied":[0]},
          {"setting":"toneSquelch","original":[4],"applied":[0]},
          {"setting":"menu.119","original":[0],"applied":[1]},
          {"setting":"rfGain","original":"nonsense","applied":[2,85]}
        ]}
        """
        defaults.set(Data(json.utf8), forKey: RigPrepStore.key(radio))
        let loaded = try XCTUnwrap(RigPrepStore(defaults: defaults).load(radio))
        XCTAssertEqual(loaded.settings, [.autoNotch, .menuItem(119)])
    }

    func testEachRadioKeepsItsOwnSnapshot() {
        let store = RigPrepStore(defaults: defaults)
        let a = RadioID(rawValue: "radio-a"), b = RadioID(rawValue: "radio-b")
        store.save(RigPrepSnapshot(entries: [notchOn]), for: a)
        store.save(RigPrepSnapshot(entries: [usbToFM]), for: b)
        XCTAssertEqual(store.load(a)?.settings, [.autoNotch])
        XCTAssertEqual(store.load(b)?.settings, [.mode])
        store.save(RigPrepSnapshot(), for: a)
        XCTAssertNil(store.load(a))
        XCTAssertEqual(store.load(b)?.settings, [.mode], "clearing one radio leaves the other owed")
    }

    /// A crash left radio A prepared. The next connect finds the notch
    /// already off and changes the mode again; the merge keeps the stored
    /// originals and adds only what is new.
    func testACrashRecoveryMerge() {
        let store = RigPrepStore(defaults: defaults)
        let radio = RadioID(rawValue: "radio-a")
        store.save(RigPrepSnapshot(entries: [notchOn, usbToFM]), for: radio)

        var recovered = store.load(radio) ?? RigPrepSnapshot()
        // This session: the operator had put the radio in FM (not FM-D)
        // by hand after the crash; the connect writes FM-D. And NR, not in
        // the stored snapshot, is new.
        recovered.record(contentsOf: [
            Entry(setting: .mode, original: [0x05, 0x01, 0x00, 0x00], applied: [0x05, 0x01, 0x01, 0x01]),
            Entry(setting: .noiseReduction, original: [0x01], applied: [0x00]),
        ])
        store.save(recovered, for: radio)

        let final = store.load(radio)
        XCTAssertEqual(final?.entry(for: .mode)?.original, [0x01, 0x02, 0x00, 0x00],
                       "the operator's USB on FIL2 from before the crash, not the FM seen this time")
        XCTAssertEqual(final?.entry(for: .autoNotch)?.original, [0x01])
        XCTAssertEqual(final?.entry(for: .noiseReduction)?.original, [0x01])
        XCTAssertEqual(final?.settings, [.autoNotch, .mode, .noiseReduction])
    }
}
