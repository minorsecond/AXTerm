import Foundation

/// The one-line summaries under the sections of the iOS settings list, so
/// the operator can check what the station is set up as without opening
/// each screen.
nonisolated enum SettingsListFooter {
    /// Under General: the base callsign, and the addresses the radios go on
    /// the air with when those differ from it. "K0EPI · on air as K0EPI-7,
    /// K0EPI-10".
    static func station(callsign: String, onAir: Set<String>) -> String {
        let base = StationCallsignRules.base(of: callsign)
        guard !base.isEmpty else { return "No callsign set" }
        let others = onAir.map { $0.uppercased() }.filter { $0 != base }.sorted()
        guard !others.isEmpty else { return base }
        return "\(base) \u{b7} on air as \(others.joined(separator: ", "))"
    }

    /// Under Radios: with one radio its name and where its link goes, since
    /// the endpoint belongs to the radio; with several, their names.
    static func radios(_ radios: [RadioProfile]) -> String {
        switch radios.count {
        case 0:
            return "No radio set up"
        case 1:
            let radio = radios[0]
            let endpoint = radio.displayEndpoint
            let title = RadioDetailView.title(for: radio)
            return endpoint.isEmpty || endpoint == title ? title : "\(title) \u{b7} \(endpoint)"
        default:
            return radios.map(RadioDetailView.title(for:)).joined(separator: ", ")
        }
    }
}
