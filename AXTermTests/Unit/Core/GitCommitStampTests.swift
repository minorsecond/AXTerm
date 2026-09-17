import XCTest
@testable import AXTerm

/// The build phase that runs Scripts/stamp-git-commit.sh, checked end to
/// end against the bundle these tests are running out of.
///
/// The script is written never to fail a build, which makes a break in it
/// silent: events keep arriving, just with no commit on them. That is
/// exactly the state the app sat in between removing the runtime git call
/// and adding the script, and nothing noticed for a day.
///
/// Reading the built Info.plist is the honest check. Running the script
/// from here is not: the test host inherits the app's sandbox, where it
/// exits at its own guards without reaching anything worth testing.
final class GitCommitStampTests: XCTestCase {

    private var stamped: String? {
        Bundle.main.object(forInfoDictionaryKey: SentryConfiguration.infoPlistGitCommitKey) as? String
    }

    func testTheBuiltAppCarriesTheCommitItWasBuiltFrom() throws {
        let value = try XCTUnwrap(stamped, "the key itself comes from Info.plist and must exist")
        XCTAssertNotEqual(value, "unknown",
                          "the xcconfig placeholder is still here, so the build phase did not run. "
                          + "A build from a source tree with no git leaves this too.")

        let sha = value.replacingOccurrences(of: "-dirty", with: "")
        XCTAssertEqual(sha.count, 12, value)
        XCTAssertTrue(sha.allSatisfy(\.isHexDigit), value)
    }

    /// The two halves have to agree. The script writes it, the
    /// configuration reads it, and nobody checks them against each other
    /// anywhere else.
    func testTheConfigurationAcceptsWhatTheScriptWrote() throws {
        let value = try XCTUnwrap(stamped)
        try XCTSkipIf(value == "unknown", "not stamped; the test above says so")

        XCTAssertEqual(
            SentryConfiguration.resolveGitCommit(infoPlistValue: value, environmentVariables: [:]),
            value,
            "a reader that narrows to bare hex would drop every dirty build")
    }
}
