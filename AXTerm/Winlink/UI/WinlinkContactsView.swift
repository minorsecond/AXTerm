import SwiftUI

/// Address book: searchable contact table with editor sheet.
struct WinlinkContactsView: View {

    @ObservedObject var viewModel: WinlinkContactsViewModel
    /// Starts a compose to the given address (from a contact row).
    var onCompose: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search name, callsign, email…", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                Spacer()
                if let error = viewModel.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Button {
                    viewModel.beginNewContact()
                } label: {
                    Label("New Contact", systemImage: "person.badge.plus")
                }
                .help("Add a contact. Contacts autocomplete in the compose window's To and Cc fields.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if viewModel.contacts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(viewModel.searchText.isEmpty
                         ? "No contacts yet — add people you exchange mail with."
                         : "No matches")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                #if os(iOS)
                touchList
                #else
                contactsTable
                #endif
            }
        }
        .sheet(item: $viewModel.editingContact) { _ in
            WinlinkContactEditorSheet(viewModel: viewModel)
        }
    }

#if os(iOS)
    /// The same contacts as a touch list.
    ///
    /// `Table` renders only its **first** column on iOS, and this table's
    /// first column is a 24pt favourite star — so the address book drew a
    /// row of stars and nothing else, which reads as data loss rather than a
    /// layout bug. Exactly the trap `WinlinkMessageList` documents; this
    /// table was missed when that one was fixed.
    private var touchList: some View {
        List(viewModel.contacts) { contact in
            Button {
                viewModel.edit(contact)
            } label: {
                row(for: contact)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .leading) {
                Button {
                    viewModel.toggleFavorite(contact)
                } label: {
                    Label(contact.favorite ? "Unstar" : "Star",
                          systemImage: contact.favorite ? "star.slash" : "star")
                }
                .tint(.yellow)
            }
            .swipeActions(edge: .trailing) {
                if let address = contact.preferredAddress {
                    Button {
                        onCompose(address)
                    } label: { Label("Message", systemImage: "square.and.pencil") }
                        .tint(.accentColor)
                }
            }
        }
        .listStyle(.plain)
    }

    /// Name first, then the address that would actually be used to reach
    /// them — the two facts a contact exists for.
    @ViewBuilder
    private func row(for contact: WinlinkContactRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: contact.favorite ? "star.fill" : "star")
                .foregroundStyle(contact.favorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                .font(.footnote)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName.isEmpty ? "(no name)" : contact.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(contact.displayName.isEmpty ? .secondary : .primary)

                if !contact.callsign.isEmpty {
                    Text(contact.callsign)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !contact.smtpEmail.isEmpty {
                    Text(contact.smtpEmail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                let extras = [contact.organization, contact.phone]
                    .filter { !$0.isEmpty }
                if !extras.isEmpty {
                    Text(extras.joined(separator: " \u{00B7} "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
#endif

    private var contactsTable: some View {
        Table(viewModel.contacts) {
            TableColumn("") { contact in
                Button {
                    viewModel.toggleFavorite(contact)
                } label: {
                    Image(systemName: contact.favorite ? "star.fill" : "star")
                        .foregroundStyle(contact.favorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(contact.favorite ? "Favorite — shown first in suggestions" : "Mark as favorite")
            }
            .width(24)

            TableColumn("Name") { contact in
                Text(contact.displayName)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Callsign") { contact in
                Text(contact.callsign).font(.body.monospaced())
            }
            .width(min: 70, ideal: 90)

            TableColumn("Email") { contact in
                Text(contact.smtpEmail).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Phone") { contact in
                Text(contact.phone).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Organization") { contact in
                Text(contact.organization).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)

            TableColumn("") { contact in
                HStack(spacing: 6) {
                    if let address = contact.preferredAddress {
                        Button("Compose") { onCompose(address) }
                            .help("Compose a message to \(address)")
                    }
                    Button("Edit") { viewModel.edit(contact) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .width(min: 130, ideal: 140)
        }
        .platformInsetTable()
        .contextMenu(forSelectionType: WinlinkContactRecord.ID.self) { ids in
            if let id = ids.first, let contact = viewModel.contacts.first(where: { $0.id == id }) {
                Button("Edit…") { viewModel.edit(contact) }
                Button(contact.favorite ? "Remove Favorite" : "Mark Favorite") {
                    viewModel.toggleFavorite(contact)
                }
                Divider()
                Button("Delete Contact", role: .destructive) { viewModel.delete(contact) }
            }
        }
    }
}

/// Full contact editor.
struct WinlinkContactEditorSheet: View {

    @ObservedObject var viewModel: WinlinkContactsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.editingContact != nil {
                Form {
                    Section("Identity") {
                        TextField("Name", text: binding(\.displayName))
                        TextField("Callsign", text: binding(\.callsign), prompt: Text("e.g. W1AW or KE7XO-10"))
                        TextField("Email", text: binding(\.smtpEmail), prompt: Text("routed via the Winlink internet gateway"))
                        Toggle("Favorite", isOn: binding(\.favorite))
                    }
                    Section("Details") {
                        TextField("Phone", text: binding(\.phone))
                        TextField("Organization", text: binding(\.organization))
                        TextField("Position / title", text: binding(\.positionTitle))
                        TextField("Grid square", text: binding(\.gridSquare))
                    }
                    Section("Address") {
                        TextField("Street", text: binding(\.street))
                        HStack {
                            TextField("City", text: binding(\.city))
                            TextField("State", text: binding(\.state)).frame(maxWidth: 80)
                            TextField("ZIP", text: binding(\.postalCode)).frame(maxWidth: 100)
                        }
                    }
                    Section("Notes") {
                        TextEditor(text: binding(\.notes))
                            .frame(minHeight: 60)
                            .font(.body)
                    }
                }
                .formStyle(.grouped)

                Divider()
                HStack {
                    if viewModel.editingContact?.id != nil {
                        Button("Delete", role: .destructive) {
                            if let contact = viewModel.editingContact {
                                viewModel.delete(contact)
                                viewModel.editingContact = nil
                                dismiss()
                            }
                        }
                    }
                    Spacer()
                    if let error = viewModel.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                    Button("Cancel") {
                        viewModel.editingContact = nil
                        dismiss()
                    }
                    Button("Save") {
                        if viewModel.saveEditingContact() {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 440, minHeight: 480)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<WinlinkContactRecord, Value>) -> Binding<Value> {
        // Nil-safe: SwiftUI can call a field's getter during the sheet's
        // dismissal pass, after a successful save already cleared
        // editingContact — a force-unwrap here crashes on every save.
        Binding(
            get: { (viewModel.editingContact ?? .empty())[keyPath: keyPath] },
            set: { viewModel.editingContact?[keyPath: keyPath] = $0 })
    }
}
