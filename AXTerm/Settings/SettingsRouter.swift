//
//  SettingsRouter.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/8/26.
//

import SwiftUI
import Combine

/// Central router for managing Settings navigation and deep linking.
/// Injected as an EnvironmentObject into the settings hierarchy.
class SettingsRouter: ObservableObject {
    /// Singleton for easy access from non-SwiftUI contexts (like AppDelegates or menu actions)
    static let shared = SettingsRouter()

    /// Injected by the main window view via @Environment(\.openSettings).
    /// Must be set before navigate(to:) is called.
    /// Opens the app's settings.
    ///
    /// Supplied by whichever shell is running: on macOS the `Settings` scene
    /// sets it, on iOS the root view sets it to switch tabs. Left nil the
    /// "Open Settings" button silently does nothing, which is exactly what
    /// happened on iPad before the iOS shell wired it up.
    var openAction: (() -> Void)?
    
    // MARK: - State
    
    /// The currently selected top-level tab
    @Published var selectedTab: SettingsTab = .general
    
    /// The specific section to highlight/scroll to within the selected tab
    @Published var highlightSection: SettingsSection?
    
    // MARK: - Navigation
    
    /// Navigate to a specific settings tab and optionally scroll to a section.
    /// - Parameters:
    ///   - tab: The destination tab.
    ///   - section: Optional section ID to scroll to and highlight.
    @MainActor
    func navigate(to tab: SettingsTab, section: SettingsSection? = nil) {
        // 1. Switch Tab
        if selectedTab != tab {
            selectedTab = tab
        }
        
        // 2. Handle Deep Link (Highlight/Scroll)
        if let section = section {
            // Slight delay to allow tab switch animation / view mounting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.highlightSection = section
                
                // Auto-clear highlight after 1.5s to remove the visual cue
                // We keep it long enough for the user to see "this is where you are"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if self.highlightSection == section {
                        self.highlightSection = nil
                    }
                }
            }
        }
        
        // 3. Bring Window to Front. Only meaningful where windows exist —
        // a handheld shows one thing at a time and is already frontmost.
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
        openAction?()
    }
}

/// Identifiers for top-level tabs in the Settings window.
nonisolated enum SettingsTab: Hashable {
    case general
    case notifications
    case network
    case transmission
    case winlink
    case bbs
    case advanced
    case linkDebug
}

/// Identifiers for specific sections within tabs (for deep linking).
nonisolated enum SettingsSection: Hashable {
    case linkLayer
    case adaptiveTransmission
    case axdpProtocol
    case netRomNode
    case beacon
    case ping
    case fileTransfer
}
