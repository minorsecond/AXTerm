import Combine
import Foundation

/// The state behind the Add Radio sheet: which step it is on, the radio it
/// is setting up, and how to leave nothing behind when it is canceled.
///
/// The radio is real from the first step. The connection views write to a
/// `RadioProfile` in settings, and testing the link needs a radio the engine
/// can open, so a draft kept anywhere else would mean a second copy of every
/// transport form. Instead a new radio is added switched off, so nothing
/// connects while the operator is still choosing, and canceling takes it
/// away again (`AppSettingsStore.discardRadio`). Setting up a radio that
/// already exists (first-run setup, on a fresh install's one radio) keeps a
/// copy of it, and canceling puts the copy back.
@MainActor
final class AddRadioFlow: ObservableObject, Identifiable {

    enum Mode: Equatable {
        /// Add a radio to the station.
        case new
        /// Set up a radio the station already has.
        case configure(RadioID)
    }

    /// The steps, in order. Channel comes before Identity because the SSIDs
    /// worth suggesting depend on what the radio is for.
    enum Step: Int, CaseIterable, Comparable {
        case connect
        case channel
        case identity
        case basics
        case done

        var title: String {
            switch self {
            case .connect: return "Connect"
            case .channel: return "Channel"
            case .identity: return "Identity"
            case .basics: return "Basics"
            case .done: return "Done"
            }
        }

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    let id = UUID()
    let mode: Mode
    let radioID: RadioID
    let settings: AppSettingsStore

    @Published var step: Step = .connect
    /// Whether this radio's link came up while the sheet was open.
    @Published private(set) var linkWasUp = false
    /// Set once the sheet has been finished or canceled, so the other of
    /// the two cannot run as well (the sheet also cancels on disappear).
    private(set) var isClosed = false
    private let original: RadioProfile?

    init(settings: AppSettingsStore, mode: Mode) {
        self.settings = settings
        self.mode = mode
        switch mode {
        case .new:
            let added = settings.addRadio()
            // No name, so the default follows the transport ("Direwolf",
            // the Bluetooth device's own name), and off until finished.
            settings.updateRadio(added.id) {
                $0.name = ""
                $0.enabled = false
            }
            radioID = added.id
            original = nil
            settings.noteRadioDraft(added.id)
        case .configure(let id):
            radioID = id
            original = settings.radio(id)
        }
    }

    var radio: RadioProfile {
        settings.radio(radioID) ?? RadioProfile(id: radioID, name: "")
    }

    /// Back works from every step after the first, Done included, so the
    /// operator can change something they see on the summary.
    var canGoBack: Bool { step > .connect }

    func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        step = following
    }

    func back() {
        guard canGoBack, let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Switch the radio on and bring its link up, to see that it works.
    func testLink(using connect: () -> Void) {
        if !radio.enabled { settings.updateRadio(radioID) { $0.enabled = true } }
        connect()
    }

    /// Note the link's state, so a cancel knows whether frames may already
    /// be stored against this radio.
    func observe(_ state: KISSLinkState) {
        if state == .connected, !linkWasUp { linkWasUp = true }
    }

    func setChannel(_ channel: RadioChannel) {
        settings.updateRadio(radioID) { channel.apply(to: &$0) }
    }

    /// Give the radio this SSID under the station callsign. Refused with no
    /// station callsign, since "-5" is not a callsign.
    func setSSID(_ ssid: Int) {
        let base = settings.myCallsign.uppercased()
        guard !base.isEmpty else { return }
        settings.updateRadio(radioID) { $0.callsign = ssid == 0 ? base : "\(base)-\(ssid)" }
    }

    var ssid: Int? {
        StationCallsignRules.ssidUnderStation(radio.callsign, station: settings.myCallsign)
    }

    /// Finish: the radio is switched on and kept. Returns it, for the caller
    /// to open its page.
    @discardableResult
    func finish() -> RadioID {
        guard !isClosed else { return radioID }
        isClosed = true
        if mode == .new {
            settings.updateRadio(radioID) { $0.enabled = true }
            settings.noteRadioDraft(nil)
        }
        SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
        return radioID
    }

    /// Cancel: a new radio goes away, an existing one gets its settings back.
    func cancel() {
        guard !isClosed else { return }
        isClosed = true
        switch mode {
        case .new:
            settings.discardRadio(radioID, linkWasUp: linkWasUp)
            settings.noteRadioDraft(nil)
        case .configure:
            if let original, settings.radio(radioID) != original {
                settings.updateRadio(radioID) { $0 = original }
            }
        }
    }
}

/// SSIDs worth offering a radio, by what it is for.
///
/// APRS has a published convention, so the offers are the three most radios
/// are: a fixed home station (0), a mobile (9) and a handheld (7). Packet has
/// none, so the offers are simply the lowest SSIDs no other radio of this
/// station uses. Either way an SSID another radio already has is skipped.
nonisolated enum SSIDSuggestion {
    static let aprsTypical = [0, 9, 7]

    static func suggest(for channel: RadioChannel, taken: Set<Int>, count: Int = 3) -> [Int] {
        switch channel {
        case .aprs:
            let typical = aprsTypical.filter { !taken.contains($0) }
            let spare = SSIDConvention.range.filter { !taken.contains($0) && !typical.contains($0) }
            return Array((typical + spare).prefix(count))
        case .packet:
            return Array(SSIDConvention.range.filter { !taken.contains($0) }.prefix(count))
        }
    }

    /// The SSIDs the station's other radios already go on the air with.
    @MainActor
    static func taken(by settings: AppSettingsStore, except radio: RadioID) -> Set<Int> {
        let station = settings.myCallsign
        return Set(settings.activeRadios
            .filter { $0.id != radio }
            .compactMap { StationCallsignRules.ssidUnderStation($0.callsign, station: station) })
    }
}
