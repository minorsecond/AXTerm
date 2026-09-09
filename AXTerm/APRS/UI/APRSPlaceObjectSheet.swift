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

    @State private var name = ""
    @State private var comment = ""
    @State private var choice: Choice = .incident
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Place an object")
                .font(.headline)
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

            Text("Transmits to every station in range. It stays on their maps until you "
                 + "stand it down or six hours pass without anyone repeating it.")
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
        .onAppear { nameFocused = true }
    }

    private func transmit() {
        let (table, code) = choice.symbol
        failure = onTransmit(name, table, code, comment)
        if failure == nil { onCancel() }
    }
}
