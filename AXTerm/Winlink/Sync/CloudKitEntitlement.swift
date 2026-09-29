import Foundation
#if os(macOS)
import Security
#endif

/// Whether this build is allowed to open a CloudKit container at all.
///
/// `CKContainer(identifier:)` does not fail when the container is missing
/// from the app's entitlements. It calls `os_crash` and takes the process
/// down. There is no error to catch and no value to inspect afterwards, so
/// the only way to survive an unentitled build is to ask before calling.
///
/// That sounds theoretical until a Debug build gets signed ad hoc. A binary
/// built with code signing off carries no entitlements at all, launches
/// fine, reaches `App.init()`, builds the sync transport, and dies before a
/// window appears — a crash dialog with nothing in it that names iCloud
/// (2026-09-16).
nonisolated enum CloudKitEntitlement {

    /// The entitlement CloudKit tests. `com.apple.developer.icloud-services`
    /// matters for the container to work, but it is not what the trap looks
    /// at, so checking it here would refuse builds that would have run.
    static let containersKey = "com.apple.developer.icloud-container-identifiers"

    /// True when `containerID` is safe to hand to `CKContainer`.
    static func permits(_ containerID: String) -> Bool {
        #if os(macOS)
        return permits(containerID, declared: declaredContainers())
        #else
        // iOS and iPadOS cannot install an app without a provisioning
        // profile, so the unsigned build this guards against cannot exist
        // there — and `SecTask` is not in the public iOS SDK to check with.
        return true
        #endif
    }

    /// The decision on its own, separated from reading the signature so it
    /// can be tested without needing a binary signed a particular way.
    ///
    /// A nil list is the ad-hoc case: the entitlement is absent. A list that
    /// exists but omits this container gets the same answer, because
    /// CloudKit traps on both.
    static func permits(_ containerID: String, declared: [String]?) -> Bool {
        guard let declared else { return false }
        return declared.contains(containerID)
    }

    #if os(macOS)
    /// The container identifiers in this process's own code signature.
    ///
    /// Read from the running binary rather than from the `.entitlements`
    /// file in the project, because the two disagree in exactly the case
    /// worth catching: the file declares the container, and the build that
    /// was signed without it does not.
    static func declaredContainers() -> [String]? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let value = SecTaskCopyValueForEntitlement(task, containersKey as CFString, nil)
        return value as? [String]
    }
    #endif
}
