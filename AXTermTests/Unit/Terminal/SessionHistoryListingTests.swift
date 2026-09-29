import XCTest
@testable import AXTerm

/// What the History screen lists, and how it labels what is not this
/// device's own.
///
/// The labelling is the safety feature. A transcript from the home rig
/// sitting unmarked in the iPad's list would read as something the iPad
/// did, and an operator planning a connect from it would be planning from
/// another antenna's result. So every remote row carries its origin, remote
/// rows never share a section with local ones, and nothing remote appears at
/// all unless the operator asked.
final class SessionHistoryListingTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_756_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func session(_ remote: String, at offset: TimeInterval = 0,
                         tags: [String] = [], transcript: String = "") -> TerminalSession {
        TerminalSession(remote: remote, startedAt: t(offset), endedAt: t(offset + 60),
                        outcome: .closed, transcript: transcript, tags: tags)
    }

    private func remote(_ remote: String, at offset: TimeInterval = 0,
                        station: String = "K0EPI-7", device: String = "mac",
                        deviceName: String? = "Ross\u{2019}s Mac",
                        transcript: String = "") -> TerminalSessionPayload {
        TerminalSessionPayload(
            session: session(remote, at: offset, transcript: transcript),
            provenance: WinlinkSyncProvenance(station: station, deviceID: device,
                                              gridSquare: "DM79", observedAt: t(offset + 60)),
            deviceName: deviceName)
    }

    // MARK: The toggle

    /// Off means off: not hidden behind a filter, absent.
    func testOtherDevicesAreAbsentUnlessAskedFor() {
        let sections = SessionHistoryListing.sections(
            local: [session("N0CVL-10")],
            remote: [remote("KB5YZB-7")],
            showsOtherDevices: false, query: "", tag: nil)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].rows.map(\.session.remote), ["N0CVL-10"])
        XCTAssertTrue(sections.allSatisfy { !$0.isRemote })
    }

    /// With nothing from elsewhere, the list is the plain list — no
    /// "This device" heading over the only section there is.
    func testALocalOnlyListHasNoHeading() {
        let sections = SessionHistoryListing.sections(
            local: [session("N0CVL-10")], remote: [],
            showsOtherDevices: true, query: "", tag: nil)

        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
    }

    // MARK: Separation

    /// Local first, under its own heading, then one section per device —
    /// never interleaved by date, however tempting a single timeline is.
    func testRemoteRowsLiveInTheirOwnSectionsAfterLocalOnes() {
        let sections = SessionHistoryListing.sections(
            local: [session("N0CVL-10", at: -3_600)],
            remote: [remote("KB5YZB-7", at: 0, device: "mac", deviceName: "Ross\u{2019}s Mac"),
                     remote("W0ARP-10", at: -60, device: "iphone", deviceName: "iPhone"),
                     remote("DRLNOD", at: -7_200, device: "mac", deviceName: "Ross\u{2019}s Mac")],
            showsOtherDevices: true, query: "", tag: nil)

        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0].title, "This device")
        XCTAssertFalse(sections[0].isRemote)
        XCTAssertEqual(sections[0].rows.map(\.session.remote), ["N0CVL-10"])

        XCTAssertTrue(sections[1].isRemote)
        XCTAssertTrue(sections[2].isRemote)
        // Devices sorted by name so the order is stable across reloads.
        XCTAssertEqual(sections[1].title, "iPhone")
        XCTAssertEqual(sections[2].title, "Ross\u{2019}s Mac")
        XCTAssertEqual(sections[2].rows.map(\.session.remote), ["KB5YZB-7", "DRLNOD"],
                       "newest first within a device")
    }

    /// Every remote row says where it came from, in words, on the row.
    func testEveryRemoteRowIsAttributed() {
        let sections = SessionHistoryListing.sections(
            local: [], remote: [remote("KB5YZB-7", station: "K0EPI-7", deviceName: "Ross\u{2019}s Mac")],
            showsOtherDevices: true, query: "", tag: nil)

        let row = try! XCTUnwrap(sections.first?.rows.first)
        XCTAssertEqual(row.origin.label, "From K0EPI-7 on Ross\u{2019}s Mac")
        XCTAssertEqual(sections[0].attribution, "Connected from K0EPI-7 on Ross\u{2019}s Mac · DM79")
    }

    /// A device with no name is still named — by the short form of its
    /// installation ID — rather than becoming an anonymous "elsewhere".
    func testANamelessDeviceIsStillIdentified() {
        let sections = SessionHistoryListing.sections(
            local: [], remote: [remote("KB5YZB-7", device: "0F9E8D7C-1234", deviceName: nil)],
            showsOtherDevices: true, query: "", tag: nil)

        XCTAssertEqual(sections[0].title, "Device 0F9E8D7C")
        XCTAssertEqual(sections[0].rows[0].origin.label, "From K0EPI-7 on device 0F9E8D7C")
    }

    /// A local row is not attributed: this device is the default, and a
    /// label on every row would make the remote label mean nothing.
    func testLocalRowsCarryNoAttribution() {
        let sections = SessionHistoryListing.sections(
            local: [session("N0CVL-10")], remote: [],
            showsOtherDevices: true, query: "", tag: nil)

        XCTAssertNil(sections[0].rows[0].origin.label)
        XCTAssertEqual(sections[0].rows[0].origin, .thisDevice)
    }

    /// Row IDs cannot collide across origins even for the same session ID.
    func testRowIDsAreDistinctAcrossOrigins() {
        let shared = session("N0CVL-10")
        let sections = SessionHistoryListing.sections(
            local: [shared],
            remote: [TerminalSessionPayload(
                session: shared,
                provenance: WinlinkSyncProvenance(station: "K0EPI-7", deviceID: "mac",
                                                  gridSquare: nil, observedAt: t(60)),
                deviceName: "Mac")],
            showsOtherDevices: true, query: "", tag: nil)

        let ids = sections.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: Filtering

    /// Search reaches both sides, so "what did any of my radios say to
    /// DRLNOD" is one query.
    func testTheQueryAppliesToBothSides() {
        let sections = SessionHistoryListing.sections(
            local: [session("N0CVL-10"), session("DRLNOD")],
            remote: [remote("DRLNOD"), remote("KB5YZB-7")],
            showsOtherDevices: true, query: "drl", tag: nil)

        XCTAssertEqual(sections.flatMap { $0.rows.map(\.session.remote) }, ["DRLNOD", "DRLNOD"])
    }

    /// Tags are local annotations; a tag filter therefore hides every
    /// remote row rather than pretending remote rows have tags.
    func testATagFilterShowsOnlyLocalRowsCarryingIt() {
        let sections = SessionHistoryListing.sections(
            local: [session("N0CVL-10", tags: ["net"]), session("W0ARP-10")],
            remote: [remote("KB5YZB-7")],
            showsOtherDevices: true, query: "", tag: "net")

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].rows.map(\.session.remote), ["N0CVL-10"])
    }

    /// An empty section is dropped — a device heading with nothing under it
    /// after a search reads as a bug.
    func testEmptySectionsAreDropped() {
        let sections = SessionHistoryListing.sections(
            local: [session("N0CVL-10")],
            remote: [remote("KB5YZB-7")],
            showsOtherDevices: true, query: "N0CVL", tag: nil)

        XCTAssertEqual(sections.count, 1)
        XCTAssertFalse(sections[0].isRemote)
    }

    // MARK: Count line

    func testTheCountLineSaysWhatIsShownAgainstWhatIsStored() {
        XCTAssertEqual(SessionHistoryListing.countLine(shown: 1, total: 1, remoteShown: 0), "1 session")
        XCTAssertEqual(SessionHistoryListing.countLine(shown: 3, total: 3, remoteShown: 0), "3 sessions")
        XCTAssertEqual(SessionHistoryListing.countLine(shown: 2, total: 5, remoteShown: 0), "2 of 5 sessions")
        XCTAssertEqual(SessionHistoryListing.countLine(shown: 5, total: 5, remoteShown: 2),
                       "5 sessions · 2 from other devices")
    }

    // MARK: A truncated transcript says so

    func testATruncatedTranscriptIsMarkedOnTheRow() {
        let long = String(repeating: "x", count: TerminalSessionPayload.transcriptByteLimit + 10)
        let sections = SessionHistoryListing.sections(
            local: [], remote: [remote("KB5YZB-7", transcript: long)],
            showsOtherDevices: true, query: "", tag: nil)

        guard case .otherDevice(let origin) = sections[0].rows[0].origin else {
            return XCTFail("expected a remote origin")
        }
        XCTAssertTrue(origin.transcriptTruncated)
    }
}
