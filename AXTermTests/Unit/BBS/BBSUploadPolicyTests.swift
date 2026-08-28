import XCTest
@testable import AXTerm

/// Accepting a file from whoever is on the other end of the radio.
///
/// The filename is chosen by a stranger and becomes a file on the operator's
/// disk. Most of what follows is about that one string.
final class BBSUploadPolicyTests: XCTestCase {

    private func policy(enabled: Bool = true,
                        inbox: Bool = true,
                        maxFileBytes: Int = 100 * 1024,
                        quotaBytes: Int = 20 * 1024 * 1024,
                        usedBytes: Int = 0,
                        uploadsThisCall: Int = 0) -> BBSUploadPolicy {
        BBSUploadPolicy(isEnabled: enabled, hasInbox: inbox,
                        maxFileBytes: maxFileBytes, quotaBytes: quotaBytes,
                        usedBytes: usedBytes, uploadsThisCall: uploadsThisCall)
    }

    // MARK: - Gates

    /// Sharing out and taking in are different decisions.
    func testOffByDefault() {
        XCTAssertEqual(BBSUploadPolicy().decide(filename: "a.txt", size: 10),
                       .reject(reason: "this station does not accept uploads"))
    }

    func testNoInboxMeansNoUploads() {
        guard case .reject(let reason) =
                policy(inbox: false).decide(filename: "a.txt", size: 10) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(reason.contains("sysop"), reason)
    }

    func testAcceptsAnOrdinaryFile() {
        XCTAssertEqual(policy().decide(filename: "notes.txt", size: 4_096),
                       .accept(filename: "notes.txt"))
    }

    func testTooLargeIsRefusedWithTheLimit() {
        guard case .reject(let reason) =
                policy(maxFileBytes: 100 * 1024).decide(filename: "a.bin", size: 200 * 1024) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(reason.contains("100K"), reason)
    }

    func testEmptyFilesAreRefused() {
        guard case .reject = policy().decide(filename: "a.txt", size: 0) else {
            return XCTFail("expected a refusal")
        }
    }

    func testQuotaIsEnforcedAgainstWhatIsAlreadyThere() {
        let sut = policy(quotaBytes: 10_000, usedBytes: 9_000)
        guard case .reject(let reason) = sut.decide(filename: "a.txt", size: 2_000) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(reason.contains("full"), reason)
        XCTAssertTrue(sut.decide(filename: "a.txt", size: 500).isAccept)
    }

    func testPerCallLimit() {
        guard case .reject(let reason) =
                policy(uploadsThisCall: 3).decide(filename: "a.txt", size: 10) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(reason.contains("per call"), reason)
    }

    // MARK: - Filenames

    func testDirectoryComponentsAreStripped() {
        XCTAssertEqual(BBSUploadPolicy.sanitize("/etc/passwd"), "passwd")
        XCTAssertEqual(BBSUploadPolicy.sanitize("../../notes.txt"), "notes.txt")
    }

    /// A caller has no business creating a dotfile.
    func testHiddenFilesAreNotCreatable() {
        XCTAssertEqual(BBSUploadPolicy.sanitize(".bashrc"), "bashrc")
        XCTAssertEqual(BBSUploadPolicy.sanitize("../../.ssh/authorized_keys"),
                       "authorized_keys")
        XCTAssertNil(BBSUploadPolicy.sanitize("..."))
    }

    func testNamesThatSurviveToNothingAreRefused() {
        XCTAssertNil(BBSUploadPolicy.sanitize(""))
        XCTAssertNil(BBSUploadPolicy.sanitize("   "))
        XCTAssertNil(BBSUploadPolicy.sanitize("."))
        XCTAssertNil(BBSUploadPolicy.sanitize(".."))
        XCTAssertNil(BBSUploadPolicy.sanitize("/"))
    }

    /// A whitelist, not a blocklist: anything unexpected becomes an
    /// underscore rather than being reasoned about.
    func testUnexpectedCharactersBecomeUnderscores() {
        XCTAssertEqual(BBSUploadPolicy.sanitize("net;rm -rf.txt"), "net_rm -rf.txt")
        XCTAssertEqual(BBSUploadPolicy.sanitize("a\u{0}b.txt"), "a_b.txt")
        XCTAssertEqual(BBSUploadPolicy.sanitize("naïve.txt"), "na_ve.txt")
    }

    func testOrdinaryNamesSurviveIntact() {
        XCTAssertEqual(BBSUploadPolicy.sanitize("ICS-213 form v2.txt"),
                       "ICS-213 form v2.txt")
    }

    func testAbsurdlyLongNamesAreCutButKeepTheirExtension() {
        let long = String(repeating: "a", count: 300) + ".txt"
        let result = try! XCTUnwrap(BBSUploadPolicy.sanitize(long))
        XCTAssertLessThanOrEqual(result.count, 64)
        XCTAssertTrue(result.hasSuffix(".txt"), result)
    }

    // MARK: - Collisions

    /// A caller replacing a file the operator already has is a way to change
    /// what the station serves.
    func testUploadsNeverOverwrite() {
        XCTAssertEqual(BBSUploadPolicy.uniqueName("notes.txt", taken: []), "notes.txt")
        XCTAssertEqual(BBSUploadPolicy.uniqueName("notes.txt", taken: ["notes.txt"]),
                       "notes-2.txt")
        XCTAssertEqual(BBSUploadPolicy.uniqueName("notes.txt",
                                                  taken: ["notes.txt", "notes-2.txt"]),
                       "notes-3.txt")
    }

    /// macOS filesystems are usually case-insensitive, so a collision that
    /// differs only in case is still a collision.
    func testCollisionsIgnoreCase() {
        XCTAssertEqual(BBSUploadPolicy.uniqueName("Notes.TXT", taken: ["notes.txt"]),
                       "Notes-2.TXT")
    }

    func testExtensionlessCollisions() {
        XCTAssertEqual(BBSUploadPolicy.uniqueName("README", taken: ["README"]), "README-2")
    }
}
