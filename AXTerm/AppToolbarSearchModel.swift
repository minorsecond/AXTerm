import SwiftUI
import Combine

/// Scopes for contextual search
enum SearchScope: String, CaseIterable {
    case terminal = "Terminal"
    case packets = "Packets"
    case routes = "Routes"
    case analytics = "Analytics"
}

/// Shared model for managing the application's top-bar search state
@MainActor
final class AppToolbarSearchModel: ObservableObject {
    /// The current search query
    @Published var query: String = ""
    
    /// The current search scope (corresponds to the active navigation/view)
    @Published var scope: SearchScope = .terminal
    
    init() {}
    
    /// Clear the current search
    func clear() {
        query = ""
    }
}
