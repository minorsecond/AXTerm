import SwiftUI

/// The colour each coverage ring is drawn in.
///
/// Four rings can be on the map at once — two directions for each of two
/// radios — so the colour is the only thing telling them apart, and it is
/// defined once here rather than at each of the three places that draw them:
/// the MapKit renderer, the SwiftUI map, and the legend that explains both.
///
/// Blue and purple are the two ways of proving somebody decoded us; teal is
/// the other direction, and it borrows the colour the path layer already uses
/// for a frame heard direct, which is the same evidence.
nonisolated extension CoverageEstimate.Evidence {

    var ringColor: Color {
        switch self {
        case .answered: return .blue
        case .digipeated: return .purple
        case .heardDirect: return .teal
        }
    }

    var ringPlatformColor: PlatformColor {
        switch self {
        case .answered: return .systemBlue
        case .digipeated: return .systemPurple
        case .heardDirect: return .systemTeal
        }
    }

    /// What the ring is called when more than one is drawn and "Coverage"
    /// would name two different measurements.
    var ringLabel: String {
        switch self {
        case .answered: return "Answered"
        case .digipeated: return "Repeated"
        case .heardDirect: return "Hearing"
        }
    }
}
