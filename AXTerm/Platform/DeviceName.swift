import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension WinlinkSyncDevice {
    /// The name a person calls this device — "Ross's Mac", "iPad".
    ///
    /// Stamped on records this device publishes so another device can say
    /// where they came from in words rather than in eight hex characters.
    /// On iOS the system gives the model name rather than the personal name
    /// unless an entitlement is held; that still tells the operator which
    /// radio it was. Nil only where the platform says nothing at all.
    @MainActor
    static func localName() -> String? {
        #if canImport(UIKit)
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
        #elseif os(macOS)
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? nil : name
        #else
        return nil
        #endif
    }
}
