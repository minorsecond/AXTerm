import XCTest
@testable import AXTerm

/// Whether a build may open a CloudKit container.
///
/// The decision is tested against a supplied list rather than against this
/// test runner's own signature: the runner is signed however the machine
/// that built it was set up, so asserting on the real one would pass or fail
/// for reasons that have nothing to do with the rule.
final class CloudKitEntitlementTests: XCTestCase {

    private let container = CloudKitSyncTransport.defaultContainerID

    /// The ad-hoc case: signed with code signing off, so the binary carries
    /// no entitlements at all. This is the one that used to take the process
    /// down at launch.
    func testAnAbsentEntitlementRefuses() {
        XCTAssertFalse(CloudKitEntitlement.permits(container, declared: nil))
    }

    /// An entitlement that exists but lists other containers is the same
    /// refusal — CloudKit traps on this too.
    func testAnEntitlementWithoutThisContainerRefuses() {
        XCTAssertFalse(CloudKitEntitlement.permits(
            container, declared: ["iCloud.com.example.other"]))
    }

    func testAnEmptyListRefuses() {
        XCTAssertFalse(CloudKitEntitlement.permits(container, declared: []))
    }

    func testTheDeclaredContainerIsPermitted() {
        XCTAssertTrue(CloudKitEntitlement.permits(container, declared: [container]))
    }

    /// An app may ship several containers; ours only has to be among them.
    func testOneOfSeveralDeclaredContainersIsPermitted() {
        XCTAssertTrue(CloudKitEntitlement.permits(
            container, declared: ["iCloud.com.example.other", container]))
    }

    /// The identifier the transport asks for has to be the one the
    /// entitlements file declares, or a correctly signed build would still
    /// be refused.
    func testTheDefaultContainerMatchesTheEntitlementsFile() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Winlink
            .deletingLastPathComponent()   // Unit
            .deletingLastPathComponent()   // AXTermTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("AXTerm/AXTerm.entitlements")
        let plist = try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: Any],
            "could not read \(url.path)")
        let declared = try XCTUnwrap(
            plist[CloudKitEntitlement.containersKey] as? [String],
            "the macOS entitlements file declares no iCloud containers")

        XCTAssertTrue(CloudKitEntitlement.permits(container, declared: declared),
                      "\(container) is not in \(declared)")
    }
}
