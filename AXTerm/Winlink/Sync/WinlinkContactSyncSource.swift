import Foundation

/// The address book, carried between the operator's devices.
///
/// `WinlinkSyncPolicy` has always declared `.contact` syncable — "an address
/// book is about people, not equipment" — but nothing implemented it, so the
/// controller configured four sources and contacts were not among them. The
/// settings panel meanwhile told the operator that contacts sync. This closes
/// that gap.
nonisolated struct WinlinkContactSyncSource: WinlinkSyncSource {

    let kind: WinlinkSyncPolicy.Kind = .contact

    private let store: ContactStore
    private let now: @Sendable () -> Date

    init(store: ContactStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    // MARK: - Identity

    /// A contact's identity across devices is the address it reaches, not its
    /// rowid.
    ///
    /// Row 5 on the Mac is a different person from row 5 on the iPad, so
    /// syncing the number would overwrite whoever happened to occupy it —
    /// silently, and differently on each device. Callsigns are matched
    /// case-insensitively because "k0nts" and "K0NTS" are one station, and
    /// email likewise.
    ///
    /// A contact with neither address is still a real entry (a name and a
    /// phone number is a useful thing to carry), so the name is the fallback
    /// key rather than a reason to refuse to sync it.
    static func recordID(for contact: WinlinkContactRecord) -> String? {
        let callsign = contact.callsign.trimmingCharacters(in: .whitespaces)
        if !callsign.isEmpty { return "call:" + callsign.uppercased() }
        let email = contact.smtpEmail.trimmingCharacters(in: .whitespaces)
        if !email.isEmpty { return "mail:" + email.lowercased() }
        let name = contact.displayName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return "name:" + name.lowercased() }
        // No name, no callsign, no address: nothing to match on, and nothing
        // worth sending.
        return nil
    }

    // MARK: - Wire form

    /// Everything except the rowid and the local recency stamp.
    ///
    /// `lastUsedAt` drives "recently used" suggestions and is a fact about
    /// *this* device's habits, so it stays home — the same reasoning that
    /// keeps the gateway ladder local.
    nonisolated struct Payload: Codable, Equatable, Sendable {
        var displayName: String
        var callsign: String
        var smtpEmail: String
        var phone: String
        var organization: String
        var positionTitle: String
        var gridSquare: String
        var street: String
        var city: String
        var state: String
        var postalCode: String
        var notes: String
        var favorite: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ contact: WinlinkContactRecord) {
            displayName = contact.displayName
            callsign = contact.callsign
            smtpEmail = contact.smtpEmail
            phone = contact.phone
            organization = contact.organization
            positionTitle = contact.positionTitle
            gridSquare = contact.gridSquare
            street = contact.street
            city = contact.city
            state = contact.state
            postalCode = contact.postalCode
            notes = contact.notes
            favorite = contact.favorite
            createdAt = contact.createdAt
            updatedAt = contact.updatedAt
        }

        /// Applies onto an existing row, keeping its local identity.
        func merged(into existing: WinlinkContactRecord) -> WinlinkContactRecord {
            var result = existing
            result.displayName = displayName
            result.callsign = callsign
            result.smtpEmail = smtpEmail
            result.phone = phone
            result.organization = organization
            result.positionTitle = positionTitle
            result.gridSquare = gridSquare
            result.street = street
            result.city = city
            result.state = state
            result.postalCode = postalCode
            result.notes = notes
            result.favorite = favorite
            // The earlier creation date wins: a contact created on the Mac in
            // March and first synced to a new iPad today was not created today.
            result.createdAt = min(existing.createdAt, createdAt)
            result.updatedAt = updatedAt
            // `id` and `lastUsedAt` are deliberately untouched.
            return result
        }

        func asNewContact() -> WinlinkContactRecord {
            merged(into: WinlinkContactRecord.empty(now: createdAt))
        }
    }

    // MARK: - WinlinkSyncSource

    func localRecords() async throws -> [WinlinkSyncRecord] {
        let contacts = try store.contacts()
        var seen = Set<String>()
        var records: [WinlinkSyncRecord] = []
        for contact in contacts {
            guard let id = Self.recordID(for: contact) else { continue }
            // Two local rows can share a key — the same person entered twice
            // with different capitalisation. Publishing both would make the
            // pair fight over one record every pass, so the most recently
            // edited one represents them.
            if seen.contains(id) { continue }
            seen.insert(id)
            let payload = try JSONEncoder().encode(Payload(contact))
            records.append(WinlinkSyncRecord(
                kind: .contact, id: id,
                modifiedAt: contact.updatedAt, payload: payload))
        }
        return records
    }

    @discardableResult
    func apply(_ records: [WinlinkSyncRecord]) async throws -> Int {
        guard !records.isEmpty else { return 0 }

        // Indexed once: a mailbox with a few hundred contacts would otherwise
        // do a linear scan per incoming record.
        var byKey: [String: WinlinkContactRecord] = [:]
        for contact in try store.contacts() {
            guard let key = Self.recordID(for: contact) else { continue }
            if let existing = byKey[key], existing.updatedAt >= contact.updatedAt { continue }
            byKey[key] = contact
        }

        var changed = 0
        for record in records {
            guard record.kind == .contact else { continue }
            guard let payload = try? JSONDecoder().decode(Payload.self, from: record.payload) else {
                // A record written by a newer version. Skipping one contact is
                // better than failing the pass and stalling the mailbox.
                continue
            }

            if let existing = byKey[record.id] {
                // Last write wins. Equal stamps mean the same edit arriving
                // back — not a change, and not worth a database write.
                guard payload.updatedAt > existing.updatedAt else { continue }
                _ = try store.saveContact(payload.merged(into: existing))
            } else {
                _ = try store.saveContact(payload.asNewContact())
            }
            changed += 1
        }
        return changed
    }
}
