import SwiftUI

/// Asking once for the ground around this station.
///
/// Path profiles need elevation, and until now getting it meant knowing that
/// a map page had an offline menu with a terrain section in it. Fetching it
/// silently instead would have been tens of megabytes from a US government
/// service on somebody's launch, which is not a decision to make on their
/// behalf.
///
/// So: asked once, with the cost, the source, and what it buys on the face of
/// it. Declining is a real option that costs the operator nothing they cannot
/// get later — every station page still offers the one or two tiles its own
/// path needs.
struct HomeTerrainConsentSheet: View {

    let estimate: ElevationStorage.Estimate
    let gridSquare: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .padding(.top, 4)

            Text("Store terrain for your area?")
                .font(.title3.weight(.semibold))

            // What it buys, before what it costs. The cost is meaningless
            // without knowing what it is for.
            Text("Station pages can then show the ground between you and the "
                 + "other station — whether a path is clear, and what a hill "
                 + "in the way actually costs you in signal.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Everything an operator needs to judge it, said plainly rather
            // than hidden behind a disclosure triangle.
            VStack(alignment: .leading, spacing: 6) {
                row("externaldrive", "\(estimate.tileCount) tiles, "
                    + "\(estimate.sizeDescription), kept on this device")
                row("globe.americas", "From the USGS 3DEP elevation service")
                row("mappin.and.ellipse", "The area around \(gridSquare.uppercased()), "
                    + "and wherever you move to")
                row("wifi.slash", "Works offline afterwards \u{2014} nothing is fetched again")
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                // Not "Not Now": this answer stands. Saying so is the
                // difference between a choice and a deferral the operator
                // expects to be asked about again.
                Button("No Thanks", action: onDecline)
                    .keyboardShortcut(.cancelAction)
                Button("Download", action: onAccept)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 2)

            Text("Asked once. Either way you can change it under Terrain in "
                 + "offline maps, and any station page can fetch the tiles for its "
                 + "own path.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 380)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .frame(width: 14)
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
