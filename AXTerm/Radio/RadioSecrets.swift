import Foundation

/// The radio's secrets, kept out of the profile and its JSON: only the
/// Keychain holds them, keyed by the radio's id. Today that is the Wi-Fi
/// (Icom LAN) password. The profile records only whether one is set.
nonisolated enum RadioSecrets {
    private static let store = KeychainStore(service: "com.axterm.radio")

    private static func lanAccount(_ id: RadioID) -> String { "lan-password.\(id.rawValue)" }

    /// Store or clear the Wi-Fi password for a radio. An empty string
    /// removes it. Returns whether a password is now set.
    @discardableResult
    static func setLANPassword(_ password: String, for id: RadioID) -> Bool {
        if password.isEmpty {
            _ = store.remove(account: lanAccount(id))
            return false
        }
        return store.setString(password, account: lanAccount(id))
    }

    static func lanPassword(for id: RadioID) -> String? {
        store.string(account: lanAccount(id))
    }

    /// The full read, so callers can tell "no password saved" from "a
    /// password is saved this build cannot unlock" — the latter is what a
    /// rebuild's new code signature causes, and it must not read as a wrong
    /// password to the radio.
    static func readLANPassword(for id: RadioID) -> KeychainStore.ReadOutcome {
        store.read(account: lanAccount(id))
    }

    static func hasLANPassword(for id: RadioID) -> Bool {
        if case .found = store.read(account: lanAccount(id)) { return true }
        return false
    }

    /// When a radio is deleted, its secrets go with it.
    static func forget(_ id: RadioID) {
        _ = store.remove(account: lanAccount(id))
    }
}
