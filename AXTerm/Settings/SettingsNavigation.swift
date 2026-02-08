//
//  SettingsNavigation.swift
//  AXTerm
//
//  Created for Transmission Configure Action
//

import SwiftUI
import Combine

enum SettingsTab: String, CaseIterable, Hashable {
    case general = "General"
    case notifications = "Notifications"
    case network = "Network"
    case transmission = "Transmission"
    case advanced = "Advanced" // For history, diagnostics
}

class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    
    @Published var selectedTab: SettingsTab = .general
    
    private init() {}
    
    /// Open settings window and select specific tab
    func openSettings(tab: SettingsTab) {
        // Update tab first
        selectedTab = tab
        
        // Open the settings window
        // Note: In standard macOS SwiftUI app lifecycle, sending showSettingsWindow: selector works
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        
        // Activate the app to bring window to front
        NSApp.activate(ignoringOtherApps: true)
    }
}
