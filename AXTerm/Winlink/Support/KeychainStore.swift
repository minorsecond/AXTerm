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

    @discardableResult
    func setString(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        // Any failure other than success: recreate the item. This recovers
        // the case where a rebuilt binary (new code signature) lost access
        // to the old item — updating it fails with errSecAuthFailed, so
        // delete-and-add is the only way re-entering a credential can work.
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        var addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // The orphaned item survived the first delete — try once more.
            SecItemDelete(query as CFDictionary)
            addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if addStatus != errSecSuccess {
            NSLog("[Keychain] setString failed for %@: update=%d add=%d", account, updateStatus, addStatus)
        }
        return addStatus == errSecSuccess
    }

    func string(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                // errSecAuthFailed here usually means a rebuilt binary lost
                // access to the item — re-entering the credential recreates it.
                NSLog("[Keychain] read failed for %@: status=%d", account, status)
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
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
