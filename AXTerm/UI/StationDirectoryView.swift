import SwiftUI

/// What the stations around here run, browsable.
///
/// Everything on this screen was announced by a station or observed being
/// done — nothing is inferred and nothing was asked for over the air. The
/// confidence badge on each row says which of the two it was, because the
/// difference matters: a declared bulletin board is a station's own word
/// about itself, while an observed digipeater repeated a frame we watched.
struct StationDirectoryView: View {

    let store: StationServiceStore?
    /// Opens an identity page. Nil makes rows inert rather than dead-looking.
    var onSelect: ((String) -> Void)?

    @State private var listings: [StationDirectory.Listing] = []
    @State private var query = ""
    @State private var service: StationServiceParser.Service?
    @State private var loadError: String?

    private var filtered: [StationDirectory.Listing] {
        StationDirectory.filter(listings, query: query, service: service)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
        }
        .task { load() }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            message(loadError, systemImage: "exclamationmark.triangle")
        } else if listings.isEmpty {
            message("Nothing heard yet. Stations announce what they run in ID and beacon frames \u{2014} this fills in as they do, and keeps what it learns between launches.",
                    systemImage: "antenna.radiowaves.left.and.right")
        } else if filtered.isEmpty {
            message("No station here matches that.", systemImage: "magnifyingglass")
        } else {
            List(filtered) { listing in
                row(listing)
            }
            #if os(macOS)
            .listStyle(.inset)
            #endif
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Callsign, alias, or service", text: $query)
                .textFieldStyle(.plain)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                #endif

            Picker("", selection: $service) {
                Text("All services").tag(StationServiceParser.Service?.none)
                ForEach(StationDirectory.availableServices(in: listings), id: \.self) { option in
                    Text(option.label).tag(StationServiceParser.Service?.some(option))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Narrows to stations running one kind of service. Only services something has actually announced or been seen doing are offered.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func row(_ listing: StationDirectory.Listing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(listing.callsign)
                    .font(.headline.monospaced())
                if let alias = listing.alias {
                    Text(alias)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("The name this station announced for itself. Operators call nodes by alias far more often than by callsign.")
                }
                Spacer(minLength: 8)
                if let lastHeard = listing.lastHeard {
                    Text(lastHeard, style: .relative)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("When this station was last heard announcing or doing any of this.")
                }
            }

            ForEach(listing.entries) { entry in
                HStack(spacing: 6) {
                    Text(entry.service.label)
                        .font(.callout)
                    Text(entry.confidence.label)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(entry.confidence == .demonstrated
                                    ? Color.green.opacity(0.18)
                                    : Color.secondary.opacity(0.15),
                                    in: Capsule())
                        .help(entry.confidence == .demonstrated
                              ? "Observed doing this \u{2014} it repeated a frame while we were listening. Only digipeating can be proven this way; nothing a node or BBS does is visible in a frame header."
                              : "The station said so in an ID or beacon. Its own word, which is the only announcement most services ever make \u{2014} but it may describe something it used to run.")
                    Spacer(minLength: 0)
                    Text("\(entry.timesHeard)\u{00D7}")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .help("How many times this has been heard. A service announced once may have been a passing station; one announced hourly is a fixture.")
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelect?(listing.callsign) }
    }

    private func load() {
        guard let store else {
            loadError = "The station directory could not be opened."
            return
        }
        do {
            listings = StationDirectory.listings(from: try store.allServices())
            loadError = nil
        } catch {
            loadError = "The station directory could not be read: \(error.localizedDescription)"
        }
    }
}
