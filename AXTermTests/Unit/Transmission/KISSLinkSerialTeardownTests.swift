import Darwin
import XCTest
@testable import AXTerm

/// A serial link that has been closed stays closed and lets go of its port.
///
/// From the 2026-09-30 RF test (Docs/LiveRFTest-2026-09-30.md, bug 7): after
/// Disconnect, and after the radio was moved to another transport, lsof still
/// showed AXTerm holding the TNC4's /dev/cu.usbmodem… port.
///
/// The first two tests never open anything: the device path does not exist,
/// so an open attempt only checks for the file and reports `.failed`. The
/// last runs against a pty, as `SerialDescriptorOwnershipTests` does.
@MainActor
final class KISSLinkSerialTeardownTests: XCTestCase {

    private static let missingPath = "/dev/cu.axterm-test-no-such-device"

    private func missingDeviceLink() -> KISSLinkSerial {
        KISSLinkSerial(config: SerialConfig(devicePath: Self.missingPath,
                                            baudRate: 115200,
                                            autoReconnect: true))
    }

    /// For a condition that should *not* come about: wait, then let the
    /// caller look. Named apart from a wait that fails on timeout.
    private func waitUntilOrGiveUp(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        await waitUntilOrGiveUp(timeout: timeout, condition)
        if !condition() {
            XCTFail("timed out after \(timeout)s waiting for: \(what)", file: file, line: line)
        }
    }

    /// A wake after the operator closed the link must not open it. Serial
    /// used the protocol's default resume, which is a plain open().
    func testAWakeAfterCloseDoesNotReopen() async {
        let link = missingDeviceLink()
        link.open()
        await waitUntil("the open attempt to fail on the missing device") { link.state == .failed }
        link.close()
        await waitUntil("the link to close") { link.state == .disconnected }
        XCTAssertFalse(link.hasPendingReconnect, "closing cancels the retry")

        link.resume()
        await waitUntilOrGiveUp(timeout: 0.5) { link.state != .disconnected }
        XCTAssertEqual(link.state, .disconnected, "a closed link stays closed through a wake")
        XCTAssertFalse(link.hasPendingReconnect)
    }

    /// A sleep is not a Disconnect: the link is still wanted and the wake
    /// tries again.
    func testAWakeAfterASleepTriesAgain() async {
        let link = missingDeviceLink()
        link.open()
        await waitUntil("the open attempt to fail on the missing device") { link.state == .failed }
        link.suspend()
        await waitUntil("the link to go down for the sleep") { link.state == .disconnected }
        XCTAssertFalse(link.hasPendingReconnect, "no retry runs while asleep")

        link.resume()
        await waitUntil("the wake to try the device again") { link.state == .failed }
        XCTAssertTrue(link.hasPendingReconnect, "and keep trying, as before the sleep")
        link.close()
    }

    /// A link dropped right after close() (the manager removing it when its
    /// radio moved to another transport) must still close its descriptor.
    /// The poll timer's cancel handler did the closing and needed `self`,
    /// which was gone by the time the handler ran.
    func testALinkReleasedRightAfterCloseLetsGoOfThePort() async throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 256)
        try XCTSkipUnless(openpty(&master, &slave, &name, nil, nil) == 0, "no pty available")
        Darwin.close(slave)
        defer { Darwin.close(master) }
        let slavePath = String(cString: name)

        var link: KISSLinkSerial? = KISSLinkSerial(config: SerialConfig(devicePath: slavePath,
                                                                        baudRate: 115200,
                                                                        autoReconnect: false))
        link?.open()
        // finishOpen sleeps a second for a TNC to settle before it is open.
        await waitUntil("the link to open the pty", timeout: 4) { link?.state == .connected }
        XCTAssertTrue(Self.processHolds(slavePath), "the link holds the pty while open")

        link?.close()
        link = nil
        await waitUntilOrGiveUp(timeout: 1.5) { !Self.processHolds(slavePath) }
        XCTAssertFalse(Self.processHolds(slavePath), "the descriptor was left open after the link went away")
    }

    /// Whether any descriptor in this process is open on `path`, the way
    /// lsof would see it.
    private static func processHolds(_ path: String) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for fd in 0..<getdtablesize() {
            guard fcntl(fd, F_GETPATH, &buffer) != -1 else { continue }
            if String(cString: buffer) == path { return true }
        }
        return false
    }
}
