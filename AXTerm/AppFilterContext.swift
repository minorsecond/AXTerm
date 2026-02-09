//
//  AppFilterContext.swift
//  AXTerm
//
//  Created by Antigravity on 2/9/26.
//

import Combine
import SwiftUI

/// Stable keys for per-view search storage.
enum ViewKey: String, Hashable, CaseIterable {
    case terminal
    case packets
    case routes
    case analytics
    case raw
    
    /// Map NavigationItem to ViewKey
    static func from(_ navigation: NavigationItem) -> ViewKey {
        switch navigation {
        case .terminal: return .terminal
        case .packets: return .packets
        case .routes: return .routes
        case .analytics: return .analytics
        case .raw: return .raw
        }
    }
}

/// Filter mode for the Terminal view.
enum TerminalFilterMode: String, CaseIterable, Identifiable {
    case dim = "Dim others"
    case filter = "Filter"
    
    var id: String { rawValue }
}

/// Global application filter state.
/// Station selection scopes (AND); search query refines (AND).
@MainActor
final class AppFilterContext: ObservableObject {
    /// The globally active station scope.
    @Published var selectedStation: StationID? = nil
    
    /// Per-view search queries.
    @Published private(set) var searchQueries: [ViewKey: String] = [:]
    
    /// Active terminal filter mode (persisted in session, not necessarily defaults).
    @Published var terminalFilterMode: TerminalFilterMode = .dim
    
    static let shared = AppFilterContext()
    
    private init() {}
    
    func query(for key: ViewKey) -> String {
        searchQueries[key] ?? ""
    }
    
    func setQuery(_ query: String, for key: ViewKey) {
        searchQueries[key] = query
    }
    
    func clearStation() {
        selectedStation = nil
    }
    
    func clearSearch(for key: ViewKey) {
        searchQueries[key] = ""
    }
    
    func clearAll() {
        selectedStation = nil
        searchQueries.removeAll()
    }
}
