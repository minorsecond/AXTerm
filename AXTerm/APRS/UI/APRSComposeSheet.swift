import SwiftUI

/// A minimal APRS message composer — addressee + text with the 67-character
/// limit shown, mirroring the BBS compose sheet's shape.
struct APRSComposeSheet: View {
    var myCallsign: String
    var initialTo: String = ""
    var onSend: (_ to: String, _ text: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var to: String
    @State private var text = ""

    init(myCallsign: String, initialTo: String = "",
         onSend: @escaping (_ to: String, _ text: String) -> Void) {
        self.myCallsign = myCallsign
        self.initialTo = initialTo
        self.onSend = onSend
        _to = State(initialValue: initialTo)
    }

    private var trimmedTo: String { to.trimmingCharacters(in: .whitespaces).uppercased() }
    private var canSend: Bool {
        !trimmedTo.isEmpty && !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("To") {
                    TextField("Callsign (e.g. W0ARP-9)", text: $to)
                        .textFieldStyleForCallsign()
                }
                Section {
                    TextField("Message", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Message")
                } footer: {
                    Text("\(text.count)/\(APRSMessage.maxTextLength)")
                        .foregroundStyle(text.count > APRSMessage.maxTextLength ? .red : .secondary)
                }
            }
            .navigationTitle("New APRS Message")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        onSend(trimmedTo, String(text.prefix(APRSMessage.maxTextLength)))
                        dismiss()
                    }
                    .disabled(!canSend)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 260)
    }
}

private extension View {
    /// Callsigns are upper-case and never autocorrected.
    @ViewBuilder func textFieldStyleForCallsign() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.characters).autocorrectionDisabled()
        #else
        self
        #endif
    }
}
