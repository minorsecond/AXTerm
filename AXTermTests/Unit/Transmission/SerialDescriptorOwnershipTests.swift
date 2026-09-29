import Darwin
import XCTest
@testable import AXTerm

/// Who owns a file descriptor, and who is allowed to close it.
///
/// The poll timer's cancel handler read `fileDescriptor` when it fired
/// rather than capturing it when it was made, and `close()` left the field
/// set while that cancel ran asynchronously. Either way a link could close
/// a descriptor number it no longer owned. The kernel hands numbers back
/// out immediately, so the victim is whatever the process opened next.
///
/// Nothing reports it: the close succeeds, and the real owner's next read
/// fails with EBADF somewhere unrelated. That is how it survived as "the
/// TNC drops out sometimes".
///
/// Run against a pty, which is a real tty and accepts the termios calls a
/// character device gets. Mind the timing: `finishOpen` sleeps a full
/// second to let a TNC settle, so nothing is open before then.
///
/// Honest about what these are: a regression guard, not a proof of the
/// fix. They pass against the unfixed code too. Reproducing the original
/// race needs the stale cancel handler to fire *after* a new descriptor has
/// been installed, and the second-long settle in the open path means the
/// cancel wins that race by a wide margin every time. Forcing the other
/// order needs a seam injected into the open path, which is a larger and
/// riskier change than the fix. What these do cover is that an ordinary
/// open, close, close and reopen against a real tty closes nothing it does
/// not own, which nothing else in the suite exercises.
final class SerialDescriptorOwnershipTests: XCTestCase {

    /// Comfortably past finishOpen's one-second stabilisation sleep.
    private static let openSettle = Duration.milliseconds(2500)

    private var master: Int32 = -1
    private var slavePath = ""

    override func setUpWithError() throws {
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 256)
        try XCTSkipUnless(openpty(&master, &slave, &name, nil, nil) == 0, "no pty available")
        Darwin.close(slave)          // the link opens the path itself
        slavePath = String(cString: name)
    }

    override func tearDown() {
        if master >= 0 { Darwin.close(master) }
        master = -1
    }

    private func makeLink() -> KISSLinkSerial {
        KISSLinkSerial(config: SerialConfig(devicePath: slavePath,
                                            baudRate: 115200,
                                            autoReconnect: false))
    }

    /// Grab a fistful of descriptors. The kernel reuses the lowest free
    /// number, so whatever the link just gave back is almost certainly
    /// among these.
    private func claimFreedDescriptors(_ count: Int = 12) -> [Int32] {
        (0..<count).compactMap { _ -> Int32? in
            let fd = Darwin.open("/dev/null", O_RDONLY)
            return fd >= 0 ? fd : nil
        }
    }

    private func assertAllStillOpen(_ fds: [Int32], _ what: String) {
        for fd in fds {
            XCTAssertNotEqual(fcntl(fd, F_GETFD), -1,
                              "\(what): fd \(fd) was closed by a link that no longer owned it")
        }
    }

    /// Closing twice must not reach the number a second time. By the second
    /// call this link has nothing of its own left to release.
    func testASecondCloseDoesNotReachADescriptorSomeoneElseNowHolds() async throws {
        let link = makeLink()
        link.open()
        try await Task.sleep(for: Self.openSettle)
        XCTAssertEqual(link.state, .connected,
                       "the link never opened the pty, so this test guards nothing")

        link.close()
        try await Task.sleep(for: .milliseconds(150))

        let sentinels = claimFreedDescriptors()
        defer { sentinels.forEach { Darwin.close($0) } }
        XCTAssertFalse(sentinels.isEmpty, "could not open a sentinel to guard")

        link.close()
        try await Task.sleep(for: .milliseconds(400))
        assertAllStillOpen(sentinels, "second close")
    }

    /// A reconnect is a close and an open in quick succession, which is the
    /// sequence that lets a stale cancel handler meet a live descriptor.
    func testReopeningAtOnceLeavesTheNewPortAlone() async throws {
        let first = makeLink()
        first.open()
        try await Task.sleep(for: Self.openSettle)
        XCTAssertEqual(first.state, .connected, "nothing was open to race over")

        first.close()
        let sentinels = claimFreedDescriptors()
        defer { sentinels.forEach { Darwin.close($0) } }

        // The first link's timer teardown runs on its own queue. Give it
        // every chance to misbehave before looking.
        try await Task.sleep(for: .milliseconds(800))
        assertAllStillOpen(sentinels, "reopen")
    }
}
