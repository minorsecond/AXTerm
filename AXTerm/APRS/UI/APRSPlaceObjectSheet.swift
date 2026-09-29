import SwiftUI
import CoreLocation

/// Naming and transmitting an object at a point on the map.
///
/// Placing an object is the only map action that keys the radio on the
/// operator's behalf, so the sheet says so rather than hiding it behind a
/// verb: the button reads "Transmit", the position it is about to claim is
/// shown, and the name is checked against the channel before the button is
/// enabled at all.
struct APRSPlaceObjectSheet: View {

    let coordinate: CLLocationCoordinate2D
    let liveObjects: [APRSObjectStore.Placed]
    let ourAddresses: Set<String>
    /// Returns a problem to show, or nil when the frame went out.
    let onTransmit: (_ name: String, _ symbolTable: Character, _ symbolCode: Character,
                     _ comment: String) -> String?
    let onCancel: () -> Void
    /// The object being moved, or nil when placing a new one.
    ///
    /// Moving is the same transmission as placing: APRS has no move, and
    /// re-sending an object under a name we already own is how it is done —
    /// which is why `APRSObjectPlacement.problem` treats our own name as no
    /// collision. Routing it through this sheet rather than through a drag
    /// keeps the one thing that matters: nothing keys the radio until the
    /// operator presses Transmit.
    var moving: APRSObjectStore.Placed?
    /// The operator's distance unit, for "Moves 1.4 mi WNW".
    var distanceInMiles: Bool = true

    @State private var name: String
    @State private var comment: String
    @State private var choice: Choice
    @State private var failure: String?
    /// A move shows only what changed until this is set. See `movePreview`.
    @State private var editingDetails = false
    @FocusState private var nameFocused: Bool

    init(coordinate: CLLocationCoordinate2D,
         liveObjects: [APRSObjectStore.Placed],
         ourAddresses: Set<String>,
         moving: APRSObjectStore.Placed? = nil,
         distanceInMiles: Bool = true,
         onTransmit: @escaping (_ name: String, _ symbolTable: Character,
                                _ symbolCode: Character, _ comment: String) -> String?,
         onCancel: @escaping () -> Void) {
        self.coordinate = coordinate
        self.liveObjects = liveObjects
        self.ourAddresses = ourAddresses
        self.moving = moving
        self.distanceInMiles = distanceInMiles
        self.onTransmit = onTransmit
        self.onCancel = onCancel
        _name = State(initialValue: moving?.report.name ?? "")
        _comment = State(initialValue: moving?.report.comment ?? "")
        // A symbol that is not one of the eight falls back rather than
        // blocking the move, and the "Others see" row makes the change
        // visible — silently altering what the channel sees is the failure
        // this picker exists to prevent.
        _choice = State(initialValue: moving.flatMap {
            Choice.matching(table: $0.report.symbolTable, code: $0.report.symbolCode)
        } ?? .incident)
    }

    /// The handful of symbols an incident net actually uses.
    ///
    /// Every one of these was verified on the air rather than chosen from
    /// memory: `TestRig/scripts/axterm_object_onair.py` transmits an object
    /// with each symbol and records how Direwolf labels it. Three of the
    /// first set were wrong — `/-` is a *House*, `/h` is a *Hospital* and not
    /// a shelter, and `\0` is the IRLP/Echolink circle — which is exactly the
    /// failure this picker exists to prevent: a symbol is the only thing most
    /// receiving stations will ever see, so a mislabelled one puts a house
    /// where the operator marked a road closure.
    enum Choice: String, CaseIterable, Identifiable {
        case incident, obstruction, aidStation, fire, water, hospital, shelter, portable
        var id: String { rawValue }

        /// What the operator is marking, in their words.
        var label: String {
            switch self {
            case .incident:    return "Incident"
            case .obstruction: return "Road blocked"
            case .aidStation:  return "Aid station"
            case .fire:        return "Fire"
            case .water:       return "Water"
            case .hospital:    return "Hospital"
            case .shelter:     return "Shelter"
            case .portable:    return "Portable station"
            }
        }

        /// Table and code. Changing one of these changes what every other
        /// station on the channel sees; `APRSObjectSymbolTests` pins each
        /// against the catalogue, and the rig capture against Direwolf.
        var symbol: (Character, Character) {
            switch self {
            case .incident:    return ("\\", "!")   // Emergency
            case .obstruction: return ("\\", "x")   // Wreck or Obstruction
            case .aidStation:  return ("/", "+")     // Red Cross
            case .fire:        return ("/", ":")     // FIRE
            case .water:       return ("/", "w")     // Water station
            case .hospital:    return ("/", "h")     // Hospital
            case .shelter:     return ("\\", "z")   // Shelter (overlay)
            case .portable:    return ("/", ";")     // Portable operation (tent)
            }
        }

        /// The choice that transmits this symbol, or nil for one this picker
        /// does not offer.
        static func matching(table: Character, code: Character) -> Choice? {
            allCases.first { $0.symbol == (table, code) }
        }

        /// How the rest of the channel will label it, from Direwolf's own
        /// decode on the rig. Shown beside the choice so the operator is
        /// picking what others will see rather than what we call it.
        var asOthersSeeIt: String {
            switch self {
            case .incident:    return "Emergency"
            case .obstruction: return "Wreck or Obstruction"
            case .aidStation:  return "Red Cross"
            case .fire:        return "FIRE"
            case .water:       return "Water Station"
            case .hospital:    return "Hospital"
            case .shelter:     return "Shelter"
            case .portable:    return "Portable operation"
            }
        }
    }

    private var problem: APRSObjectPlacement.Problem? {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return APRSObjectPlacement.problem(
            name: name, liveObjects: liveObjects, ourAddresses: ourAddresses)
    }

    private var canTransmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && problem == nil
    }


    /// How far the drop moved the object, or nil when it barely moved.
    private var movedSummary: String? {
        guard let moving else { return nil }
        return APRSObjectMove.summary(
            from: GreatCircle.Point(latitude: moving.report.latitude,
                                    longitude: moving.report.longitude),
            to: GreatCircle.Point(latitude: coordinate.latitude,
                                  longitude: coordinate.longitude),
            inMiles: distanceInMiles)
    }

    /// Hoisted out of the builder: a long conditional string inside a
    /// `VStack` is what the type checker chokes on.
    private var footnote: String {
        moving == nil
            ? "Transmits to every station in range. It stays on their maps until you "
                + "stand it down or six hours pass without anyone repeating it."
            : "Transmits to every station in range. Each one replaces the position it "
                + "already had for this object."
    }

    private static func coordinateText(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }

    /// A move, shown as a move.
    ///
    /// The full form asks what this object *is* \u{2014} name, kind, comment
    /// \u{2014} which is the placement decision, and it was already made.
    /// Re-asking it on a drag buries the only thing that changed and invites
    /// edits nobody came here to make. So the identity is stated rather than
    /// offered, and Edit details is there for the times the comment really
    /// does need fixing too.
    @ViewBuilder
    private func movePreview(_ placed: APRSObjectStore.Placed) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(APRSObjectReport.wireName(placed.report.name)
                        .trimmingCharacters(in: .whitespaces))
                    .font(.system(.body, design: .monospaced))
                Text("\u{00B7}").foregroundStyle(.secondary)
                Text(choice.asOthersSeeIt).foregroundStyle(.secondary)
            }
            if !placed.report.comment.isEmpty {
                Text(placed.report.comment)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("From").foregroundStyle(.secondary)
                    Text(Self.coordinateText(placed.report.latitude, placed.report.longitude))
                        .font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("To").foregroundStyle(.secondary)
                    Text(Self.coordinateText(coordinate.latitude, coordinate.longitude))
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .font(.caption)

            if let movedSummary {
                Label("Moves " + movedSummary, systemImage: "arrow.turn.down.right")
                    .font(.callout)
            } else {
                // Not refused \u{2014} an operator may well mean a twenty-metre
                // nudge \u{2014} but said out loud, because an accidental drag
                // looks exactly like this and nothing else would tell them.
                Label("Less than \(Int(APRSObjectMove.restingMetres)) m from where it is now.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Edit details\u{2026}") { editingDetails = true }
                .controlSize(.small)
                .padding(.top, 2)
        }
    }

    /// Name, kind and comment: the placement decision, and what Edit details
    /// reopens on a move.
    @ViewBuilder
    private var placementForm: some View {
            Text(String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Form {
                TextField("Name", text: $name, prompt: Text("ROADCLOSE"))
                    .focused($nameFocused)
                    .onSubmit { if canTransmit { transmit() } }
                Picker("Kind", selection: $choice) {
                    ForEach(Choice.allCases) { Text($0.label).tag($0) }
                }
                // The symbol is the only thing most receiving stations will
                // ever see of this object, and their label for it is not
                // necessarily ours.
                LabeledContent("Others see") {
                    Text(choice.asOthersSeeIt).foregroundStyle(.secondary)
                }
                TextField("Comment", text: $comment, prompt: Text("US-85 washed out"))
            }
            .formStyle(.grouped)

            // The name is nine characters on the wire and every other station
            // will see the truncation, so show it here rather than after.
            if !name.trimmingCharacters(in: .whitespaces).isEmpty,
               APRSObjectReport.wireName(name).trimmingCharacters(in: .whitespaces)
                != name.trimmingCharacters(in: .whitespaces).uppercased(),
               APRSObjectReport.wireName(name).trimmingCharacters(in: .whitespaces)
                != name.trimmingCharacters(in: .whitespaces) {
                Label("Goes out as \u{201C}\(APRSObjectReport.wireName(name).trimmingCharacters(in: .whitespaces))\u{201D} "
                      + "\u{2014} object names are nine characters.",
                      systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(moving == nil ? "Place an object" : "Move object")
                .font(.headline)

            if let moving, !editingDetails {
                movePreview(moving)
            } else {
                placementForm
            }

            if let problem {
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let failure {
                Label(failure, systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Transmit", action: transmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canTransmit)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { nameFocused = moving == nil }
        .onChange(of: editingDetails) { _, opened in nameFocused = opened }
    }

    private func transmit() {
        let (table, code) = choice.symbol
        failure = onTransmit(name, table, code, comment)
        if failure == nil { onCancel() }
    }
}
