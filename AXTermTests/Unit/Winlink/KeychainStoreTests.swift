import XCTest
import Security
@testable import AXTerm

/// Storing and reading a credential, and — more importantly — telling the
/// operator the truth when it cannot be read.
///
/// Field case 2026-08-31: the Winlink password "disappeared" for the second
/// time. It had not. `security find-generic-password` showed the item alive
/// in the login keychain, created 2026-08-23 and *modified that morning*,
/// under exactly the service and account the app looks up. The app still
/// said "No Winlink password found", because every failure — missing item,
/// denied item, anything — collapsed to nil.
///
/// The mechanism matters: a rebuilt binary carries a new code signature, and
/// the item's ACL is bound to the old one. macOS then permits `SecItemUpdate`
/// (writing does not require decrypting what is already there) while refusing
/// `SecItemCopyMatching`. So re-entering the password appeared to work, the
/// update succeeded, and the value stayed unreadable — which is why it kept
/// "disappearing again" no matter how many times it was typed in.
final class KeychainStoreTests: XCTestCase {

    /// A service nobody else uses, so the suite never touches the operator's
    /// real credentials.
    private var service = ""
    private var store = KeychainStore()

    override func setUp() {
        super.setUp()
        service = "com.axterm.tests.\(UUID().uuidString)"
        store = KeychainStore(service: service)
    }

    override func tearDown() {
        store.remove(account: "probe")
        super.tearDown()
    }

    // MARK: - What the status means

    /// The distinction the old code threw away, and the whole point of this
    /// type: "there is nothing saved" and "there is something saved that
    /// this build cannot open" call for opposite things from the operator.
    func testAMissingItemAndADeniedItemAreDifferentAnswers() {
        XCTAssertEqual(KeychainStore.ReadOutcome.absent.isAbsent, true)
        XCTAssertEqual(KeychainStore.ReadOutcome.unreadable(errSecAuthFailed).isAbsent, false)
    }

    /// The message an operator acts on. "Not found" sends them looking for a
    /// password they never lost; the truth sends them to the one action that
    /// actually fixes it.
    func testADeniedItemExplainsItselfAndSaysWhatToDo() throws {
        let advice = try XCTUnwrap(
            KeychainStore.ReadOutcome.unreadable(errSecAuthFailed).operatorAdvice)
        XCTAssertTrue(advice.contains("saved"), advice)
        XCTAssertTrue(advice.lowercased().contains("re-enter"), advice)
    }

    /// Nothing saved needs no explanation beyond itself.
    func testAnAbsentItemOffersNoExcuse() {
        XCTAssertNil(KeychainStore.ReadOutcome.absent.operatorAdvice)
    }

    // MARK: - Round trip

    func testAStoredValueReadsBack() {
        XCTAssertTrue(store.setString("hunter2", account: "probe"))
        XCTAssertEqual(store.string(account: "probe"), "hunter2")
        XCTAssertEqual(store.read(account: "probe"), .found("hunter2"))
    }

    func testNothingStoredIsAbsentRatherThanUnreadable() {
        XCTAssertEqual(store.read(account: "probe"), .absent)
        XCTAssertNil(store.string(account: "probe"))
    }

    /// Overwriting must leave the item readable. The old implementation
    /// preferred `SecItemUpdate`, which is exactly the call that succeeds on
    /// an item this binary is not allowed to read — so a password could be
    /// written over and over and never come back.
    func testOverwritingLeavesTheValueReadable() {
        XCTAssertTrue(store.setString("first", account: "probe"))
        XCTAssertTrue(store.setString("second", account: "probe"))
        XCTAssertEqual(store.string(account: "probe"), "second")
    }

    func testRemovingClearsIt() {
        XCTAssertTrue(store.setString("gone soon", account: "probe"))
        XCTAssertTrue(store.remove(account: "probe"))
        XCTAssertEqual(store.read(account: "probe"), .absent)
    }

    /// Removing something that was never there is not a failure — the
    /// operator's intent ("there should be no password") is satisfied.
    func testRemovingWhatIsNotThereSucceeds() {
        XCTAssertTrue(store.remove(account: "probe"))
    }
}
