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

            if let winlinkSettings {
                LabeledContent("Grid square") {
                    TextField("DM79po", text: Binding(
                        get: { winlinkSettings.gridSquare },
                        set: { winlinkSettings.gridSquare = $0.uppercased() }))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .accessibilityLabel("Grid square")
                }
                .help("A six-character locator places you within about 7 km by 5 km. "
                      + "Fine for a map pin, too coarse for a short path.")
            }

            LabeledContent("Exact coordinate") {
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
            }
            .help("Where the antenna actually is. This is the only source that describes "
                  + "the aerial rather than the operator, and it is what makes a short "
                  + "path worth analysing.")

            LabeledContent("Or look up an address") {
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

            Toggle("Use this device's location", isOn: $useDeviceLocation)
                .help("Off by default, because the radio is not necessarily with this "
                      + "device: a TNC reached over a network can be somewhere else "
                      + "entirely. Turn it on when the radio travels with the computer.")

            if useDeviceLocation, locationService?.lastLocation == nil {
                Text("No fix yet. The grid square is being used until one arrives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        if useDeviceLocation, let fix = locationService?.lastLocation {
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
