import XCTest
import GRDB
@testable import AXTerm

@MainActor
final class ContactStoreTests: XCTestCase {

    private func makeStore(now: Date = Date(timeIntervalSince1970: 1_000)) throws -> SQLiteContactStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteContactStore(dbQueue: queue, now: { now })
    }

    private func makeContact(name: String = "Jane Doe", callsign: String = "W1AW",
                             email: String = "") -> WinlinkContactRecord {
        var contact = WinlinkContactRecord.empty(now: Date(timeIntervalSince1970: 500))
        contact.displayName = name
        contact.callsign = callsign
        contact.smtpEmail = email
        return contact
    }

    func testSaveAssignsIDAndNormalizes() async throws {
        let store = try makeStore()
        let saved = try store.saveContact(makeContact(name: "  Jane Doe ", callsign: "w1aw"))
        XCTAssertNotNil(saved.id)
        XCTAssertEqual(saved.displayName, "Jane Doe")
        XCTAssertEqual(saved.callsign, "W1AW")
        XCTAssertEqual(try store.contacts().count, 1)
    }

    func testSaveRejectsEmptyContact() async throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.saveContact(.empty())) {
            XCTAssertEqual($0 as? ContactStoreError, .emptyName)
        }
    }

    func testNameDefaultsToCallsignOrEmail() async throws {
        let store = try makeStore()
        let byCall = try store.saveContact(makeContact(name: "", callsign: "KE7XO"))
        XCTAssertEqual(byCall.displayName, "KE7XO")
        let byEmail = try store.saveContact(makeContact(name: "", callsign: "", email: "a@b.co"))
        XCTAssertEqual(byEmail.displayName, "a@b.co")
    }

    func testUpdateExistingContact() async throws {
        let store = try makeStore()
        var saved = try store.saveContact(makeContact())
        saved.phone = "555-0100"
        let updated = try store.saveContact(saved)
        XCTAssertEqual(updated.id, saved.id)
        XCTAssertEqual(try store.contacts().count, 1)
        XCTAssertEqual(try store.contacts()[0].phone, "555-0100")
    }

    func testSearchMatchesNameCallsignEmailOrg() async throws {
        let store = try makeStore()
        _ = try store.saveContact(makeContact(name: "Jane Doe", callsign: "W1AW"))
        _ = try store.saveContact(makeContact(name: "Bob Ray", callsign: "KE7XO", email: "bob@example.com"))

        XCTAssertEqual(try store.searchContacts("jane").map(\.callsign), ["W1AW"])
        XCTAssertEqual(try store.searchContacts("ke7").map(\.displayName), ["Bob Ray"])
        XCTAssertEqual(try store.searchContacts("example.com").map(\.displayName), ["Bob Ray"])
        XCTAssertTrue(try store.searchContacts("nomatch").isEmpty)
    }

    func testFavoritesSortFirst() async throws {
        let store = try makeStore()
        _ = try store.saveContact(makeContact(name: "Alpha", callsign: "A1AA"))
        var favorite = makeContact(name: "Zulu", callsign: "Z9ZZ")
        favorite.favorite = true
        _ = try store.saveContact(favorite)
        XCTAssertEqual(try store.contacts().map(\.displayName), ["Zulu", "Alpha"])
    }

    func testPreferredAddress() {
        XCTAssertEqual(makeContact(callsign: "W1AW").preferredAddress, "W1AW")
        XCTAssertEqual(makeContact(callsign: "", email: "a@b.co").preferredAddress, "SMTP:a@b.co")
        XCTAssertNil(makeContact(name: "No Address", callsign: "").preferredAddress)
    }

    func testContactForAddressMatchesBothForms() async throws {
        let store = try makeStore()
        _ = try store.saveContact(makeContact(name: "Bob", callsign: "KE7XO", email: "bob@example.com"))

        XCTAssertEqual(try store.contact(forAddress: "ke7xo")?.displayName, "Bob")
        XCTAssertEqual(try store.contact(forAddress: "SMTP:bob@example.com")?.displayName, "Bob")
        XCTAssertEqual(try store.contact(forAddress: "bob@example.com")?.displayName, "Bob")
        XCTAssertNil(try store.contact(forAddress: "N0BODY"))
    }

    func testTouchContactBumpsRecency() async throws {
        let store = try makeStore()
        _ = try store.saveContact(makeContact(callsign: "W1AW"))
        try store.touchContact(address: "W1AW", at: Date(timeIntervalSince1970: 9_999))
        XCTAssertEqual(try store.contacts()[0].lastUsedAt, Date(timeIntervalSince1970: 9_999))
        // Unknown addresses are a no-op, not an error.
        XCTAssertNoThrow(try store.touchContact(address: "N0BODY", at: Date()))
    }

    func testDeleteContact() async throws {
        let store = try makeStore()
        let saved = try store.saveContact(makeContact())
        try store.deleteContact(id: saved.id!)
        XCTAssertTrue(try store.contacts().isEmpty)
        XCTAssertThrowsError(try store.deleteContact(id: saved.id!))
    }

    // MARK: - View model

    func testViewModelEditorLifecycle() async throws {
        let store = try makeStore()
        let vm = WinlinkContactsViewModel(store: store)

        vm.beginNewContact(prefillAddress: "SMTP:carol@example.org", name: "Carol")
        XCTAssertEqual(vm.editingContact?.smtpEmail, "carol@example.org")
        XCTAssertTrue(vm.saveEditingContact())
        XCTAssertEqual(vm.contacts.map(\.displayName), ["Carol"])

        vm.beginNewContact(prefillAddress: "ke7xo-10")
        XCTAssertEqual(vm.editingContact?.callsign, "KE7XO-10")
        XCTAssertTrue(vm.saveEditingContact())

        vm.searchText = "carol"
        XCTAssertEqual(vm.contacts.count, 1)
    }

    func testViewModelSuggestions() async throws {
        let store = try makeStore()
        _ = try store.saveContact(makeContact(name: "Jane", callsign: "W1AW"))
        _ = try store.saveContact(makeContact(name: "No Address Person", callsign: ""))
        let vm = WinlinkContactsViewModel(store: store)

        let suggestions = vm.suggestions(for: "ja")
        XCTAssertEqual(suggestions.map(\.callsign), ["W1AW"], "contacts without an address are not suggested")
    }
}
