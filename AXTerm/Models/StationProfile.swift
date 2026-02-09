//
//  StationProfile.swift
//  AXTerm
//
//  Created by Antigravity on 2/9/26.
//

import Combine
import Foundation

/// Represents enriched metadata and persistent state for a station.
struct StationProfile: Codable, Identifiable, Hashable {
    let id: StationID
    
    var name: String?
    var qth: String?
    var notes: String?
    
    /// Experimental: Trust or identity flags for future AXDP features
    var isTrusted: Bool = false
    
    var lastInteracted: Date?
    
    init(id: StationID) {
        self.id = id
    }
}

/// Central directory for all known stations and their profiles.
@MainActor
final class StationDirectory: ObservableObject {
    @Published private(set) var profiles: [StationID: StationProfile] = [:]
    
    static let shared = StationDirectory()
    
    private init() {}
    
    func profile(for id: StationID) -> StationProfile {
        if let existing = profiles[id] {
            return existing
        }
        let newProfile = StationProfile(id: id)
        // In the future, we would persist this or load from DB
        return newProfile
    }
    
    func updateProfile(_ profile: StationProfile) {
        profiles[profile.id] = profile
    }
}
