import SwiftUI

/// Ask one station one question.
///
/// The map's **Ping** answers a single question — "can you hear me" — and does
/// it by sending `?APRSP`, whose reply is an ordinary broadcast beacon that
/// proves nothing on its own. APRS has seven of these queries and they are not
/// interchangeable: four are answered with a message addressed back to you,
/// which is proof, and three with a broadcast, which is inference. An operator
/// choosing between them needs to know which before they transmit, not after
/// they have spent two minutes waiting.
///
/// So the choice is the screen. Every query says what comes back and whether an
/// answer can be proved, the reach picker says how far the question travels,
/// and the last result for this station sits underneath so the sheet is also
/// where the answer arrives.
struct APRSAskStationSheet: View {

    var callsign: String
    /// One line about the station under its callsign — last heard, distance,
    /// direct or via a digipeater. Nil when the caller knows nothing useful.
    var subtitle: String?
    /// What became of the last query to this station, so the sheet shows the
    /// answer rather than sending the operator back to the map for it.
    var ping: APRSPingTracker.Ping?
    var onSend: (APRSStationQuery) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Remembered across sheets: an operator who wants traces wants traces.
    @AppStorage("aprs.ask.query") private var storedQuery: String = APRSDirectedQuery.position.rawValue
    /// Remembered separately from the map's flood reach — a directed question
    /// and a channel-wide one are different decisions.
    @AppStorage("aprs.ask.reach") private var storedReach: String = APRSProbeReach.direct.rawValue
    @State private var custom: String = ""
    @State private var usingCustom = false

    private var selected: APRSDirectedQuery {
        APRSDirectedQuery(rawValue: storedQuery) ?? .position
    }

    private var reach: APRSProbeReach {
        APRSProbeReach(rawValue: storedReach) ?? .direct
    }

    private var outgoing: APRSStationQuery {
        usingCustom
            ? APRSStationQuery(callsign: callsign, custom: custom, reach: reach)
            : APRSStationQuery(callsign: callsign, kind: selected, reach: reach)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    queryList
                    reachPicker
                    footnote
                }
                .padding(16)
            }
            .navigationTitle("Ask \(callsign)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        onSend(outgoing)
                        dismiss()
                    }
                    .disabled(!outgoing.isValid)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        // A sheet on the Mac needs a size; on a phone it is the screen, and
        // asking for 440 points of width would push the content off it.
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 580)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            // A monogram rather than the station's APRS symbol: the symbol is
            // rasterised for the map at map sizes, and a blurry 40-point copy
            // of it would look worse than the callsign it stands for.
            Text(String(callsign.prefix(2)))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(callsign)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let ping {
                    HStack(spacing: 5) {
                        Image(systemName: APRSPingPresentation.icon(ping))
                            .foregroundStyle(APRSPingPresentation.tint(ping))
                        Text(APRSPingPresentation.line(ping))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .help(APRSPingPresentation.help(ping))
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Queries

    private var queryList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask for")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(APRSDirectedQuery.allCases) { query in
                    queryRow(query)
                    Divider().padding(.leading, 44)
                }
                customRow
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func queryRow(_ query: APRSDirectedQuery) -> some View {
        let isOn = !usingCustom && selected == query
        return Button {
            usingCustom = false
            storedQuery = query.rawValue
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .font(.body)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Label(query.label, systemImage: query.systemImage)
                            .font(.callout.weight(.medium))
                            .labelStyle(.titleAndIcon)
                        Text(query.token)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        evidenceBadge(query)
                    }
                    Text(query.reply)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            // The radio dot is small and the rows are tall; a tinted row is
            // what actually reads as "this is the one you are sending".
            .background(isOn ? Color.accentColor.opacity(0.10) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // "AXTerm answers this one too" lives here rather than on the row: it
        // was true of four of the seven and printed identically on each, which
        // is four lines of noise in the middle of the one comparison the
        // operator is actually making.
        .help(query.axtermAnswersIt
              ? query.help + " AXTerm answers this query when another station asks it."
              : query.help)
    }

    /// Proof versus inference, said once per row.
    ///
    /// The single most useful fact on this screen, and the one an operator
    /// cannot get from the query name: `?VER` coming back is proof the station
    /// heard you, `?APRSP` coming back is a beacon that may have been on its
    /// way regardless.
    private func evidenceBadge(_ query: APRSDirectedQuery) -> some View {
        let proof = query.isProvable
        return Text(proof ? "Replies to you" : "Broadcasts")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(proof ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15),
                        in: Capsule())
            .foregroundStyle(proof ? Color.green : Color.secondary)
            .help(proof
                  ? "Answered with a message addressed to you. A reply is proof it heard the "
                    + "query \u{2014} the only unambiguous evidence APRS offers."
                  : "Answered with an ordinary broadcast that carries no reference to the "
                    + "query. Only its timing can suggest it was an answer.")
    }

    /// Anything the spec has and this list does not.
    ///
    /// A free field rather than more rows: `?APRSH`, `?IGATE?` and the
    /// station-specific queries some software invents all have wire formats
    /// this app has no authority over, and offering a typed one is honest where
    /// guessing at a format would not be.
    private var customRow: some View {
        // The field lives outside the Button, not inside its label: a control
        // inside a button label never sees a click — the button eats it — and
        // the row would look editable and refuse to be edited.
        VStack(alignment: .leading, spacing: 6) {
            Button {
                usingCustom = true
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: usingCustom ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(usingCustom ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Something else", systemImage: "character.cursor.ibeam")
                            .font(.callout.weight(.medium))
                        if !usingCustom {
                            Text("Type any query token \u{2014} the spec has more than this list.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if usingCustom {
                TextField("?APRSH K0EPI", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit {
                        if outgoing.isValid { onSend(outgoing); dismiss() }
                    }
                Text(custom.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Sent as written, upper-cased with a leading ?."
                     : "Sends \(APRSStationQuery.normalize(custom)) to \(callsign).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .help("The queries above are the ones whose wire format this app can vouch for. "
              + "Anything else you know the format of goes here, verbatim.")
    }

    // MARK: - Reach

    private var reachPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reach")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { reach },
                set: { storedReach = $0.rawValue })) {
                ForEach(APRSProbeReach.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(reach.help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footnote

    /// The thing that surprises everybody, said where it is needed.
    private var footnote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("A station can repeat your frame and still never answer a query. Digipeating "
                 + "is AX.25 \u{2014} match a callsign in the path, retransmit, never read the "
                 + "payload. Answering is an APRS application reading the message and finding "
                 + "its own name in it. Much digipeater software does only the first.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}
