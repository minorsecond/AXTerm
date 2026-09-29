import Foundation
import Security

/// Minimal generic-password Keychain wrapper.
///
/// First Keychain use in AXTerm: the Winlink account password and the
/// CMS access key are credentials and MUST NOT live in UserDefaults
/// alongside ordinary preferences.
nonisolated struct KeychainStore: Sendable {

    let service: String

    init(service: String = "com.axterm.winlink") {
        self.service = service
    }

    /// What a read found. "Nothing is saved" and "something is saved that
    /// this build cannot open" are opposite situations for the operator, and
    /// collapsing both to nil is what made a live password look lost.
    enum ReadOutcome: Equatable, Sendable {
        case found(String)
        case absent
        case unreadable(OSStatus)

        var value: String? {
            if case let .found(value) = self { return value }
            return nil
        }

        var isAbsent: Bool { self == .absent }

        /// What to tell the operator, when there is something to tell.
        ///
        /// A denied read is not a missing password: the credential is still
        /// in the login keychain, and the fix is one action rather than a
        /// hunt for something they never lost.
        var operatorAdvice: String? {
            guard case .unreadable = self else { return nil }
            return "A password is saved, but this build of AXTerm cannot unlock it — "
                + "rebuilding the app changes its code signature, and macOS ties "
                + "Keychain access to that. Re-enter it once to rebind it."
        }
    }

    @discardableResult
    func setString(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Delete and re-add rather than update, always.
        //
        // `SecItemUpdate` is precisely the call that still *succeeds* on an
        // item this binary is no longer allowed to read: writing data does
        // not require decrypting what is already there. Preferring it meant
        // a re-entered password wrote cleanly, reported success, and stayed
        // unreadable — so the operator retyped it over and over while the
        // stale ACL survived every attempt (2026-08-31). Re-adding binds a
        // fresh ACL to the running signature, which is the only thing that
        // actually recovers the item.
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        // Credentials are needed while the exchange runs unattended after
        // first unlock, but must never leave this Mac.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // An orphan survived the delete — clear it and try once more.
            SecItemDelete(query as CFDictionary)
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status != errSecSuccess {
            NSLog("[Keychain] setString failed for %@: add=%d", account, status)
        }
        return status == errSecSuccess
    }

    /// The full answer, including why a value could not be produced.
    func read(account: String) -> ReadOutcome {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let text = String(data: data, encoding: .utf8) else {
                // Present, readable, and not text this app wrote.
                return .unreadable(status)
            }
            return .found(text)
        case errSecItemNotFound:
            return .absent
        default:
            NSLog("[Keychain] read denied for %@: status=%d", account, status)
            return .unreadable(status)
        }
    }

    func string(account: String) -> String? {
        read(account: account).value
    }

    @discardableResult
    func remove(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
