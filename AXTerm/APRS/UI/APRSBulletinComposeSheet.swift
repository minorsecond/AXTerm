import SwiftUI

/// Composing a bulletin: a broadcast to every station in range, rather than a
/// message to one.
///
/// The two things an operator has to know before sending are said on the sheet
/// rather than left to be discovered. **Nobody answers a bulletin** — it is not
/// acked and there is no reply affordance anywhere, so an operator expecting a
/// conversation is expecting the wrong thing. And **a slot is a slot**: sending
/// `BLN1` again replaces our earlier `BLN1` on every receiver, which is how a
/// correction is made and also how a careless second send erases the first.
struct APRSBulletinComposeSheet: View {
    var myCallsign: String
    var onSend: (_ identifier: Character, _ group: String, _ text: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var identifier: Character = "1"
    @State private var group = ""
    @State private var text = ""

    private var problem: APRSBulletin.Problem? {
        APRSBulletin.problem(identifier: identifier, group: group, text: text)
    }

    /// What goes in the addressee field, shown as it will be transmitted.
    private var slot: String {
        APRSBulletin.addressee(identifier: identifier, group: group)
    }

    private var isAnnouncement: Bool {
        APRSBulletin.announcementIdentifiers.contains(identifier)
    }

    private var body_: String { text.trimmingCharacters(in: .whitespaces) }
    private var overLimit: Bool { body_.count > APRSMessage.maxTextLength }

    /// Hoisted out of the view builder: the type-checker gives up on a string
    /// this long inside a `Form`, and a sentence worth reading is easier to
    /// edit here anyway.
    private var slotFooter: String {
        let base = "Goes out as \u{201C}\(slot)\u{201D}. Sending this slot again replaces what "
            + "you last put in it, on every station that hears it \u{2014} that is how a "
            + "correction is made."
        guard isAnnouncement else { return base }
        return base + " An announcement is the same frame; the convention is that it stays up "
            + "longer and is repeated less."
    }

    private var counter: String { "\(body_.count)/\(APRSMessage.maxTextLength)" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Slot", selection: $identifier) {
                        // Bulletins first: an operator sending a net
                        // announcement wants 1, not A, and the sequence
                        // numbers are what a multi-frame bulletin uses.
                        ForEach(APRSBulletin.bulletinIdentifiers, id: \.self) { c in
                            Text("Bulletin \(String(c))").tag(c)
                        }
                        ForEach(APRSBulletin.announcementIdentifiers, id: \.self) { c in
                            Text("Announcement \(String(c))").tag(c)
                        }
                    }
                    TextField("Group (optional, e.g. ARES)", text: $group)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                } header: {
                    Text("Slot")
                } footer: {
                    Text(slotFooter)
                }

                Section {
                    TextField("Bulletin", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Text")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(counter)
                            .foregroundStyle(overLimit ? Color.red : Color.secondary)
                        if let problem, !body_.isEmpty {
                            Label(problem.message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Label("Everyone in range sees this, and nobody can answer it. "
                          + "A bulletin is not acked and has no reply.",
                          systemImage: "megaphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Bulletin")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Transmit") {
                        onSend(identifier, group.trimmingCharacters(in: .whitespaces), body_)
                        dismiss()
                    }
                    .disabled(problem != nil)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 400)
    }
}
