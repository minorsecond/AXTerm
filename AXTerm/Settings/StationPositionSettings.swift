import Combine
import CoreLocation
import SwiftUI

/// Where this station is, and how well that is known.
///
/// Gathered in one place because it is one fact that half the app depends on:
/// every distance, bearing, coverage ring, plausibility check and terrain
/// profile begins here. It was previously a grid square on the Winlink tab,
/// which is a strange home for something the map and the terrain analysis
/// need, and no way at all to say anything more precise than a square about
/// 7 km across.
struct StationPositionSettings: View {

    @ObservedObject var settings: AppSettingsStore
    /// Nil when the caller has no Winlink store, in which case the grid
    /// square is not editable here.
    var winlinkSettings: WinlinkSettings?
    var locationService: StationLocationService?

    @AppStorage("station.useDeviceLocation") private var useDeviceLocation = false
    @AppStorage("station.manualLatitude") private var manualLatitude = ""
    @AppStorage("station.manualLongitude") private var manualLongitude = ""
    @AppStorage(WinlinkSettings.heightUnitIsFeetKey) private var heightUnitIsFeet = true

    @State private var isLocating = false
    /// Bumped whenever the location service publishes.
    ///
    /// `locationService` is a plain property rather than an
    /// `@ObservedObject`, because the wrapper cannot wrap an Optional. So
    /// nothing here was watching it: the row would ask for a fix and then
    /// never notice one arriving, and the "Using" line would go on naming
    /// the grid square after the GPS had answered. Requesting the fix and
    /// redrawing for it are two separate wirings, and only the first was
    /// done.
    @State private var fixRevision = 0
    @State private var geocodeError: String?
    @State private var isGeocoding = false
    @State private var address = ""

    var body: some View {
        PreferencesSection("Station position") {
            // The answer first. Everything under it is a way to improve this
            // line, and without it the operator is editing fields with no
            // idea whether they made anything better.
            if let resolved {
                LabeledContent("Using") {
                    HStack(spacing: 6) {
                        Text(resolved.summary)
                        if resolved.accuracyMetres > 1_000 {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .help("The best position available, and how far the antenna might be "
                      + "from it. Terrain profiles, coverage rings and every distance "
                      + "on the map start here.")
                if resolved.accuracyMetres > 1_000 {
                    Text("A grid square is about 7 km across, so a path shorter than "
                         + "roughly 9 km cannot be analysed from one. An exact "
                         + "coordinate fixes that.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No position set, so distances and terrain are unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Best source first, so the list reads as the ladder it is
            // rather than three unrelated fields. The one actually in force
            // says so: with three ways to set a position and a summary that
            // names only the winner, "which of these is it using?" is the
            // obvious question and nothing here was answering it.
            deviceLocationRow
            exactCoordinateRow
            addressRow
            gridSquareRow
        }
        // Turning the switch on has to go and fetch a fix. It used to set a
        // flag and nothing else, so the row sat on "No fix yet" forever
        // while the summary above kept saying grid centre — from this
        // screen the setting did nothing at all.
        .task(id: useDeviceLocation) {
            guard useDeviceLocation else { return }
            await requestFix()
        }
        .onReceive(locationServiceChanged) { _ in
            fixRevision &+= 1
        }
    }

    /// Fires when the service publishes; `Empty` when there is no service,
    /// so the modifier does not need to be conditional.
    private var locationServiceChanged: AnyPublisher<Void, Never> {
        guard let locationService else {
            return Empty<Void, Never>().eraseToAnyPublisher()
        }
        return locationService.objectWillChange
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    // MARK: - Rows

    @ViewBuilder
    private var deviceLocationRow: some View {
        Toggle(isOn: $useDeviceLocation) {
            HStack(spacing: 6) {
                Text("This device's location")
                inUseBadge(when: resolved?.source == .deviceGPS)
            }
        }
        .help("Off by default, because the radio is not necessarily with this "
              + "device: a TNC reached over a network can be somewhere else "
              + "entirely. Turn it on when the radio travels with the computer.")

        if useDeviceLocation {
            HStack(spacing: 6) {
                if isLocating {
                    ProgressView().controlSize(.small)
                    Text("Locating\u{2026}")
                } else if let error = locationService?.lastGPSError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message(for: error))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { Task { await requestFix() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                } else if let fix = deviceFix {
                    Text(String(format: "%.5f, %.5f", fix.latitude, fix.longitude))
                        .monospacedDigit()
                    Button("Refresh") { Task { await requestFix() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                } else {
                    Text("No fix yet.")
                    Button("Try Again") { Task { await requestFix() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var exactCoordinateRow: some View {
        LabeledContent {
            // labelsHidden, or each field renders its own title beside
            // itself inside a 110-point box: the editable area collapses
            // to nothing and "Longitude" hyphenates across two lines. A
            // border because without one these read as static text and
            // there is no sign the coordinate can be typed at all.
            //
            // And an explicit prompt, because hiding the label hides the
            // title outright rather than demoting it to placeholder text
            // — which left two blank boxes with no way to tell which one
            // wanted the latitude.
            HStack(spacing: 6) {
                TextField("Latitude", text: $manualLatitude,
                          prompt: Text("Latitude"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .accessibilityLabel("Latitude")
                TextField("Longitude", text: $manualLongitude,
                          prompt: Text("Longitude"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .accessibilityLabel("Longitude")
                if hasManualCoordinate {
                    Button("Clear") {
                        manualLatitude = ""
                        manualLongitude = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Exact coordinate")
                inUseBadge(when: resolved?.source == .surveyed)
            }
        }
        .help("Where the antenna actually is. This is the only source that describes "
              + "the aerial rather than the operator, and it is what makes a short "
              + "path worth analysing.")
    }

    /// Subordinate to the coordinate above, because it fills that field
    /// rather than competing with it. Titled "Or look up an address" and
    /// sitting as a peer, it read as a fourth source, which it is not.
    @ViewBuilder
    private var addressRow: some View {
        LabeledContent("From an address") {
            HStack(spacing: 6) {
                TextField("Street, city", text: $address,
                          prompt: Text("Street, city"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                    .accessibilityLabel("Address to look up")
                    .onSubmit { Task { await geocode() } }
                Button(isGeocoding ? "Looking up\u{2026}" : "Find") {
                    Task { await geocode() }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isGeocoding)
            }
        }
        .help("Fills the coordinate above from a street address. The address is sent "
              + "to Apple's geocoder; the coordinate is then kept on this device.")

        if let geocodeError {
            Text(geocodeError)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var gridSquareRow: some View {
        if let winlinkSettings {
            LabeledContent {
                TextField("DM79po", text: Binding(
                    get: { winlinkSettings.gridSquare },
                    set: { winlinkSettings.gridSquare = $0.uppercased() }))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .accessibilityLabel("Grid square")
            } label: {
                HStack(spacing: 6) {
                    Text("Grid square")
                    inUseBadge(when: resolved?.source == .gridSquare)
                }
            }
            .help("A six-character locator places you within about 7 km by 5 km. "
                  + "Fine for a map pin, too coarse for a short path.")
        }
    }

    @ViewBuilder
    private func inUseBadge(when active: Bool) -> some View {
        if active {
            Text("In use")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
                .foregroundStyle(.tint)
        }
    }

    // MARK: - GPS

    /// The last fix, and only when it really is one.
    ///
    /// `currentLocation()` falls back to the grid square when GPS fails and
    /// stores that in `lastLocation`, so taking it at face value labelled a
    /// grid centre as "Device GPS ±20 m" — a claim of 20-metre accuracy for
    /// a square 7 km across.
    private var deviceFix: StationLocation? {
        guard let last = locationService?.lastLocation, last.source == .gps else { return nil }
        return last
    }

    private func requestFix() async {
        guard let locationService else { return }
        // Off the current view update before touching state. A `.task` can
        // begin while the view is still updating, and mutating published
        // state there is what "Publishing changes from within view updates"
        // is complaining about.
        await Task.yield()
        isLocating = true
        defer { isLocating = false }
        _ = await locationService.currentLocation()
    }

    private func message(for error: GPSError) -> String {
        switch error {
        case .denied:
            return "Location access is denied. Grant it in System Settings \u{203A} "
                + "Privacy & Security \u{203A} Location Services."
        case .timeout:
            return "No fix within the time allowed."
        case .unavailable(let reason):
            return "Location unavailable: \(reason)"
        }
    }

    // MARK: - Resolving

    private var hasManualCoordinate: Bool { manualPoint != nil }

    private var manualPoint: GreatCircle.Point? {
        guard let latitude = Double(manualLatitude.trimmingCharacters(in: .whitespaces)),
              let longitude = Double(manualLongitude.trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        return GreatCircle.Point(latitude: latitude, longitude: longitude)
    }

    private var resolved: StationPosition? {
        var candidates = StationPositionResolver.Candidates()
        candidates.surveyed = manualPoint
        candidates.gridSquare = winlinkSettings
            .flatMap { Maidenhead.center(of: $0.gridSquare) }
            .map(GreatCircle.Point.init)
        if useDeviceLocation, let fix = deviceFix {
            candidates.deviceGPS = GreatCircle.Point(latitude: fix.latitude,
                                                     longitude: fix.longitude)
        }
        return StationPositionResolver.resolve(candidates)
    }

    /// Address to coordinate, filling the field the operator can then check.
    ///
    /// Deliberately writes into the coordinate boxes rather than storing a
    /// hidden result: a geocoder puts you at a building, occasionally at the
    /// wrong one, and the operator should see the number before anything
    /// relies on it.
    private func geocode() async {
        isGeocoding = true
        geocodeError = nil
        defer { isGeocoding = false }
        do {
            let marks = try await CLGeocoder().geocodeAddressString(address)
            guard let location = marks.first?.location else {
                geocodeError = "No match for that address."
                return
            }
            manualLatitude = String(format: "%.6f", location.coordinate.latitude)
            manualLongitude = String(format: "%.6f", location.coordinate.longitude)
        } catch {
            geocodeError = "Lookup failed: \(error.localizedDescription)"
        }
    }
}
