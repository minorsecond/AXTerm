import Combine
import CoreLocation
import SwiftUI

/// First-run setup's callsign step.
///
/// The field writes `settings.myCallsign` as General's does, and the store
/// keeps only the base, so an SSID typed here goes nowhere and the note
/// under the field says where it belongs.
struct SetupCallsignStep: View {
    @ObservedObject var settings: AppSettingsStore
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var base: String { StationCallsignRules.base(of: settings.myCallsign) }

    var body: some View {
        SetupCard(title: "Callsign") {
            HStack(spacing: 10) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                TextField("N0CALL", text: Binding(
                    get: { draft },
                    set: { typed in
                        draft = CallsignValidator.normalize(typed)
                        settings.myCallsign = draft
                    }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .disableAutocorrection(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .focused($focused)
                    .accessibilityLabel("Callsign")
                if CallsignValidator.isValidCallsign(settings.myCallsign) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.green)
                        .accessibilityLabel("Valid callsign")
                }
            }
            if let guidance = StationCallsignRules.ssidGuidance(
                for: draft, hasMultipleRadios: settings.hasMultipleRadios) {
                Label(guidance, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !draft.isEmpty, !CallsignValidator.isValidCallsign(draft) {
                Label("That doesn't look like a callsign yet, e.g. K0EPI.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear {
            draft = settings.myCallsign
            focused = true
        }

        SetupCard(title: "SSIDs",
                  note: "Enter your licence callsign without an SSID. You pick each radio's SSID "
                    + "when you set that radio up, so two radios never answer to the same address.") {
            Text("Each radio goes on the air as this callsign plus its own SSID, 0 to 15. What "
                 + "the SSID means depends on the radio's channel:")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow(alignment: .firstTextBaseline) {
                    channelLabel("PACKET")
                    Text("\(shownBase)-1  \(shownBase)-2")
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundStyle(base.isEmpty ? .secondary : .primary)
                    Text("No fixed meaning. Any SSID your other radios don't use.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow(alignment: .firstTextBaseline) {
                    channelLabel("APRS")
                    Text("\(shownBase)-9  \(shownBase)-7")
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundStyle(base.isEmpty ? .secondary : .primary)
                    Text("Read by other stations: 9 mobile, 7 handheld, none for a home station.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func channelLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private var shownBase: String { base.isEmpty ? "N0CALL" : base }
}

/// First-run setup's position step.
///
/// Edits the same stored values as General's Station position section,
/// under the same keys, so the two can never disagree. The read-out at the
/// top is the resolver's answer, the one the map and the beacon use.
struct SetupPositionStep: View {
    @ObservedObject var settings: AppSettingsStore
    let winlinkSettings: WinlinkSettings
    var locationService: StationLocationService?

    @AppStorage(StationPositionKeys.useDeviceLocation) private var useDeviceLocation = false
    @AppStorage(StationPositionKeys.manualLatitude) private var manualLatitude = ""
    @AppStorage(StationPositionKeys.manualLongitude) private var manualLongitude = ""

    @State private var fixRevision = 0
    @State private var isLocating = false
    @State private var address = ""
    @State private var isGeocoding = false
    @State private var geocodeError: String?

    var body: some View {
        readout
        SetupCard(title: "Set it from",
                  note: "AXTerm uses the most precise of these. A grid square is about 7 km across: "
                    + "fine for a map pin, too coarse for a short path or a terrain profile.") {
            deviceRow
            Divider()
            coordinateRow
            Divider()
            addressRow
            Divider()
            gridRow
        }
        .onReceive(locationChanges) { _ in fixRevision &+= 1 }
    }

    // MARK: Read-out

    @ViewBuilder
    private var readout: some View {
        if let resolved {
            HStack(alignment: .top, spacing: 14) {
                SetupPositionMap(position: resolved, callsign: StationCallsignRules.base(of: settings.myCallsign))
                    .frame(width: 220, height: 132)
                VStack(alignment: .leading, spacing: 8) {
                    SetupReadout(rows: [
                        ("Lat", SetupFormat.latitude(resolved.point.latitude)),
                        ("Lon", SetupFormat.longitude(resolved.point.longitude)),
                        ("Grid", Maidenhead.gridSquare(latitude: resolved.point.latitude,
                                                       longitude: resolved.point.longitude) ?? "\u{2014}"),
                        ("Error", SetupFormat.accuracy(resolved.accuracyMetres)),
                    ])
                    Label(resolved.source.label, systemImage: symbol(for: resolved.source))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(resolved.accuracyMetres > 1_000 ? .orange : .secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(SetupSurface())
        } else {
            HStack(spacing: 10) {
                Image(systemName: "location.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No position yet")
                        .font(.callout.weight(.semibold))
                    Text("Pick one of the ways below. You can skip this; distances and terrain stay off until you set it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(SetupSurface())
        }
    }

    private func symbol(for source: PositionQuality.Source) -> String {
        switch source {
        case .deviceGPS: return "location.fill"
        case .surveyed: return "scope"
        case .gridSquare: return "square.grid.3x3"
        default: return "mappin"
        }
    }

    // MARK: Rows

    private var deviceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $useDeviceLocation) {
                #if os(macOS)
                Text("This Mac's location")
                #else
                Text("This device's location")
                #endif
            }
            .onChange(of: useDeviceLocation) { _, on in
                if on { Task { await requestFix() } }
            }
            if useDeviceLocation {
                Group {
                    if isLocating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Locating\u{2026}")
                        }
                    } else if let error = locationService?.lastGPSError, deviceFix == nil {
                        Label(message(for: error), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if let fix = deviceFix {
                        Text("\(SetupFormat.latitude(fix.latitude))  \(SetupFormat.longitude(fix.longitude))")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var coordinateRow: some View {
        HStack(spacing: 8) {
            Text("Coordinates")
            Spacer(minLength: 8)
            TextField("Latitude", text: $manualLatitude)
                .frame(width: 110)
            TextField("Longitude", text: $manualLongitude)
                .frame(width: 110)
            if !manualLatitude.isEmpty || !manualLongitude.isEmpty {
                Button {
                    manualLatitude = ""
                    manualLongitude = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear the coordinate")
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
    }

    private var addressRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Address")
                Spacer(minLength: 8)
                TextField("Street, city", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { Task { await geocode() } }
                Button(isGeocoding ? "Finding\u{2026}" : "Find") { Task { await geocode() } }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isGeocoding)
            }
            if let geocodeError {
                Text(geocodeError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var gridRow: some View {
        HStack(spacing: 8) {
            Text("Grid square")
            Spacer(minLength: 8)
            if let precise = preciseLocator, precise.uppercased() != winlinkSettings.gridSquare.uppercased() {
                Button("Use \(precise)") { winlinkSettings.gridSquare = precise }
                    .help("The locator for the position above")
            }
            TextField("DM79", text: Binding(
                get: { winlinkSettings.gridSquare },
                set: { winlinkSettings.gridSquare = $0.trimmingCharacters(in: .whitespaces) }))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 90)
        }
    }

    // MARK: Resolving

    private var locationChanges: AnyPublisher<Void, Never> {
        guard let locationService else { return Empty().eraseToAnyPublisher() }
        return locationService.objectWillChange.map { _ in () }
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }

    private var deviceFix: StationLocation? {
        _ = fixRevision
        guard let last = locationService?.lastLocation, last.source == .gps else { return nil }
        return last
    }

    private var manualPoint: GreatCircle.Point? {
        StationPositionResolver.manualPoint(latitude: manualLatitude, longitude: manualLongitude)
    }

    private var resolved: StationPosition? {
        StationPositionResolver.ownStation(
            gridSquare: winlinkSettings.gridSquare,
            manualLatitude: manualLatitude,
            manualLongitude: manualLongitude,
            usesDeviceLocation: useDeviceLocation,
            deviceLocation: deviceFix)
    }

    /// A locator worked out from a position better than a grid square.
    private var preciseLocator: String? {
        guard let resolved, resolved.source != .gridSquare else { return nil }
        return Maidenhead.gridSquare(latitude: resolved.point.latitude, longitude: resolved.point.longitude)
    }

    private func requestFix() async {
        guard let locationService else { return }
        await Task.yield()
        isLocating = true
        defer { isLocating = false }
        _ = await locationService.currentLocation(maxFixAge: 0)
    }

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

    private func message(for error: GPSError) -> String {
        switch error {
        case .denied:
            return "Location access is denied. Grant it in System Settings \u{203A} Privacy & Security \u{203A} Location Services."
        case .timeout:
            #if os(macOS)
            return "No location in time. A Mac locates by Wi\u{2011}Fi, so Wi\u{2011}Fi needs to be on."
            #else
            return "No location in time. Check Location Services and try again."
            #endif
        case .unavailable(let reason):
            return "Location unavailable: \(reason)"
        }
    }
}
