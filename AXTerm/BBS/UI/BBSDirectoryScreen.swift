//
//  BBSDirectoryScreen.swift
//  AXTerm
//
//  White pages on a handheld: who a callsign belongs to, and how this station
//  knows.
//

#if os(iOS)
import SwiftUI

/// The directory list, with anything harvested from the operator's own BBS
/// sessions offered above it.
struct BBSDirectoryListScreen: View {

    @ObservedObject var service: BBSService
    @Binding var selection: String?
    /// Only used in `.pushed`, where this screen builds the entry editor
    /// itself rather than filling a detail column.
    var onOpenProfile: ((String) -> Void)?
    var presentation: BBSScreenPresentation = .tab

    @State private var newCallsign = ""
    @State private var isLookingUp = false
    @State private var showingAdd = false

    var body: some View {
        Group {
            if service.directory.isEmpty && service.suggestions.isEmpty {
                BBSEmptyState(
                    systemImage: "person.text.rectangle",
                    title: "Directory empty",
                    detail: "Callers fill this in themselves with N, NQ, NH and NZ at the "
                        + "prompt. You can also add someone here.")
            } else if presentation.ownsNavigation {
                List(selection: $selection) {
                    if !service.suggestions.isEmpty { suggestions }
                    entriesSection { entry in row(entry).tag(entry.callsign) }
                }
                .listStyle(.insetGrouped)
            } else {
                List {
                    if !service.suggestions.isEmpty { suggestions }
                    entriesSection { entry in
                        NavigationLink {
                            BBSDirectoryDetailScreen(
                                service: service,
                                entry: service.directory.first {
                                    $0.callsign == entry.callsign
                                },
                                onRemoved: { },
                                onOpenProfile: onOpenProfile,
                                presentation: .pushed)
                        } label: {
                            row(entry)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Directory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Callsign", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isLookingUp {
                    ProgressView()
                } else {
                    Button {
                        lookUp()
                    } label: {
                        Label("Look Up Callsigns", systemImage: "magnifyingglass")
                    }
                    .disabled(knownCallsigns.isEmpty)
                }
            }
        }
        .alert("Add a callsign", isPresented: $showingAdd) {
            TextField("Callsign", text: $newCallsign)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { newCallsign = "" }
            Button("Add") { addEntry() }
        } message: {
            Text("Adds an entry you can then fill in. Callers can also put themselves "
                 + "here with N at the prompt.")
        }
    }

    // MARK: - Rows

    /// The directory itself, however its rows are made to navigate.
    @ViewBuilder
    private func entriesSection<Row: View>(
        @ViewBuilder row: @escaping (WhitePagesEntry) -> Row) -> some View {
        Section {
            ForEach(service.directory) { entry in
                row(entry)
            }
        } header: {
            if !service.directory.isEmpty { Text("On file") }
        } footer: {
            // The Mac says this in a tooltip on the same button. `.help` draws
            // nothing on iOS, and an explanation hung on a toolbar button
            // would take the tap that runs it — so it is said here, where it
            // can simply be read.
            Text("Look Up Callsigns fills empty names and locations from the licence "
                 + "record, for everyone here and everyone who has called. Anything a "
                 + "caller told you is left alone. Needs \u{201C}Look up callsigns "
                 + "online\u{201D} in Settings \u{203A} Winlink.")
        }
    }

    private func row(_ entry: WhitePagesEntry) -> some View {
        let model = BBSDirectoryRowModel.make(entry)
        return VStack(alignment: .leading, spacing: 2) {
            Text(model.callsign)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
            Text(model.subtitle)
                .font(.caption)
                .foregroundStyle(model.hasName ? .secondary : .tertiary)
        }
        .padding(.vertical, 2)
    }

    /// Facts spotted in BBS sessions the operator had, waiting to be accepted.
    ///
    /// Offered rather than applied, and each with the line it was parsed from:
    /// this is a guess about another system's display format, and an operator
    /// deciding whether to trust it needs to see what was actually read.
    /// Grouped per callsign so everything claimed about one person is judged
    /// together rather than as four unrelated rows.
    @ViewBuilder
    private var suggestions: some View {
        Section {
            ForEach(BBSDirectorySuggestions.grouped(service.suggestions)) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.callsign)
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.semibold)

                    ForEach(group.candidates) { candidate in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(candidate.key.label): \(candidate.value)")
                                    .font(.callout)
                                Text(candidate.evidence)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Button("Add") { service.acceptSuggestion(candidate) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button {
                                service.dismissSuggestion(candidate)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Dismiss")
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button("Add All") { service.acceptAllSuggestions() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Dismiss All") { service.dismissAllSuggestions() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }
        } header: {
            Label(BBSDirectorySuggestions.headline(service.suggestions),
                  systemImage: "sparkle.magnifyingglass")
        } footer: {
            Text("Read from sessions you opened — nothing was asked of anyone. Recorded "
                 + "as worked-out-from-traffic, so it never overwrites what somebody "
                 + "told you.")
        }
    }

    // MARK: - Actions

    /// Everyone worth filling in: the directory itself, plus anyone who has
    /// called — a caller with no entry is exactly who this is for.
    private var knownCallsigns: [String] {
        Array(Set(service.directory.map(\.callsign)
                  + service.calls.map { BBSMessage.baseCall($0.callsign) }))
    }

    private func lookUp() {
        Task {
            isLookingUp = true
            await service.fillDirectoryFromLicences(for: knownCallsigns)
            isLookingUp = false
        }
    }

    private func addEntry() {
        let call = newCallsign.trimmingCharacters(in: .whitespaces).uppercased()
        newCallsign = ""
        guard !call.isEmpty else { return }
        // An entry with no fields would not survive a reload — the store holds
        // fields, not empty shells. Seeding the name with the callsign gives
        // the operator something to edit, and reads honestly until they do.
        service.sysopSetDirectoryField(callsign: call, key: .name, value: call)
        selection = BBSMessage.baseCall(call)
    }
}

/// One directory entry, with every field's provenance beside it.
struct BBSDirectoryDetailScreen: View {

    @ObservedObject var service: BBSService
    let entry: WhitePagesEntry?
    /// Clears the split view's selection. In `.pushed` there is no selection
    /// to clear and the screen pops itself instead.
    let onRemoved: () -> Void
    var onOpenProfile: ((String) -> Void)?
    var presentation: BBSScreenPresentation = .tab

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [WhitePagesEntry.Key: String] = [:]
    @FocusState private var editing: WhitePagesEntry.Key?
    @State private var confirmingRemoval = false

    var body: some View {
        Group {
            if let entry {
                form(entry)
            } else {
                BBSEmptyState(
                    systemImage: "person.crop.circle",
                    title: "Select a callsign",
                    detail: "White pages hold a name, a location, a home BBS and a "
                        + "postcode — the four fields every FBB mailbox has published "
                        + "for decades, and deliberately no more.")
            }
        }
        .navigationTitle(entry?.callsign ?? "Directory")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func form(_ entry: WhitePagesEntry) -> some View {
        Form {
            Section {
                ForEach(WhitePagesEntry.Key.allCases, id: \.self) { key in
                    field(key, entry: entry)
                }
            } header: {
                Text(entry.callsign).font(.system(.callout, design: .monospaced))
            } footer: {
                if let updated = entry.lastUpdated {
                    Text("Last changed "
                         + updated.formatted(date: .abbreviated, time: .shortened) + ".")
                } else {
                    Text("Nothing on file yet.")
                }
            }

            if let onOpenProfile {
                Section {
                    Button {
                        onOpenProfile(entry.callsign)
                    } label: {
                        Label("About \(entry.callsign)", systemImage: "person.crop.circle")
                    }
                }
            }

            Section {
                Button("Remove \(entry.callsign) from the directory", role: .destructive) {
                    confirmingRemoval = true
                }
            } footer: {
                Text("Callers can put themselves back at any time.")
            }
        }
        .confirmationDialog("Remove \(entry.callsign)?",
                            isPresented: $confirmingRemoval,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                service.sysopDeleteDirectoryEntry(callsign: entry.callsign)
                onRemoved()
                // A pushed screen showing an entry that no longer exists would
                // sit there empty until the operator went back themselves.
                if !presentation.ownsNavigation { dismiss() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Everything on file for this callsign goes, including anything they "
                 + "told this station themselves.")
        }
        // Committing on focus change as well as on Return: on a touch keyboard
        // the usual way to leave a field is to tap the next one, and a value
        // typed and abandoned there would otherwise be silently thrown away.
        .onChange(of: editing) { previous, focused in
            if let previous { commit(previous, entry: entry) }
            if let focused { drafts[focused] = entry.value(focused) ?? "" }
        }
        .onDisappear {
            if let editing { commit(editing, entry: entry) }
        }
    }

    private func field(_ key: WhitePagesEntry.Key, entry: WhitePagesEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // A draft shadows the stored value only while this field is being
            // edited. Letting it shadow always meant a value fetched after the
            // drafts were seeded — a licence lookup, a caller telling us their
            // name — showed as "not on file" while the row beside it showed
            // the truth.
            TextField(key.label,
                      text: Binding(
                        get: { editing == key ? (drafts[key] ?? "") : (entry.value(key) ?? "") },
                        set: { drafts[key] = $0 }),
                      prompt: Text("not on file"))
                .focused($editing, equals: key)
                .autocorrectionDisabled(key == .homeBBS)
                .textInputAutocapitalization(key == .homeBBS ? .characters : .words)
                .onSubmit {
                    commit(key, entry: entry)
                    editing = nil
                }

            if let stored = entry.fields[key] {
                HStack(spacing: 4) {
                    Image(systemName: BBSDirectoryProvenance.systemImage(for: stored.source))
                        .font(.caption2)
                    Text(BBSDirectoryProvenance.caption(key: key, field: stored))
                        .font(.caption2)
                }
                .foregroundStyle(stored.source == .selfReported ? Color.secondary : Color.orange)
                .explain("Provenance decides whether this can be trusted, and it decides "
                         + "what may overwrite it: something a caller told this station is "
                         + "never replaced by something worked out from traffic, however "
                         + "recent. Only you can clear a field.",
                         showsIndicator: false)
            } else {
                Text(key == .name
                     ? "Callers set this with N at the prompt."
                     : "Callers set this with \(key.command) at the prompt.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func commit(_ key: WhitePagesEntry.Key, entry: WhitePagesEntry) {
        guard let draft = drafts[key], draft != (entry.value(key) ?? "") else { return }
        service.sysopSetDirectoryField(callsign: entry.callsign, key: key, value: draft)
    }
}
#endif
