import Foundation
import Combine

/// Address-book list + editor state.
@MainActor
final class WinlinkContactsViewModel: ObservableObject {

    @Published private(set) var contacts: [WinlinkContactRecord] = []
    @Published var searchText: String = "" {
        didSet { reload() }
    }
    @Published var editingContact: WinlinkContactRecord?
    @Published private(set) var lastError: String?

    private let store: ContactStore

    init(store: ContactStore) {
        self.store = store
        reload()
    }

    func reload() {
        do {
            contacts = searchText.isEmpty
                ? try store.contacts()
                : try store.searchContacts(searchText)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func beginNewContact(prefillAddress: String? = nil, name: String? = nil) {
        var contact = WinlinkContactRecord.empty()
        if let prefillAddress {
            let trimmed = prefillAddress.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("SMTP:") {
                contact.smtpEmail = String(trimmed.dropFirst(5))
            } else if trimmed.contains("@") {
                contact.smtpEmail = trimmed
            } else {
                contact.callsign = trimmed.uppercased()
            }
        }
        if let name { contact.displayName = name }
        editingContact = contact
    }

    func edit(_ contact: WinlinkContactRecord) {
        editingContact = contact
    }

    /// Saves the contact currently in the editor. Returns true on success.
    @discardableResult
    func saveEditingContact() -> Bool {
        guard let contact = editingContact else { return false }
        do {
            _ = try store.saveContact(contact)
            editingContact = nil
            reload()
            return true
        } catch ContactStoreError.emptyName {
            lastError = "A contact needs at least a name, callsign, or email."
            return false
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    func delete(_ contact: WinlinkContactRecord) {
        guard let id = contact.id else { return }
        do {
            try store.deleteContact(id: id)
            reload()
        } catch {
            lastError = String(describing: error)
        }
    }

    func toggleFavorite(_ contact: WinlinkContactRecord) {
        var updated = contact
        updated.favorite.toggle()
        do {
            _ = try store.saveContact(updated)
            reload()
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Suggestions for a compose-field fragment (the text after the last
    /// comma). Empty fragment → favorites and recents.
    func suggestions(for fragment: String, limit: Int = 6) -> [WinlinkContactRecord] {
        let trimmed = fragment.trimmingCharacters(in: .whitespaces)
        let matches = (try? store.searchContacts(trimmed)) ?? []
        return Array(matches.filter { $0.preferredAddress != nil }.prefix(limit))
    }

    /// Bumps recency after a message is queued to these addresses.
    func recordUse(of addresses: [String]) {
        let now = Date()
        for address in addresses {
            try? store.touchContact(address: address, at: now)
        }
    }

    func contact(forAddress address: String) -> WinlinkContactRecord? {
        try? store.contact(forAddress: address)
    }
}
