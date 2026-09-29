//
//  BBSDirectoryPane.swift
//  AXTerm
//

import SwiftUI

// The mailbox UI is macOS-only, like the window layout it lives in. The shell,
// the store and the service are platform-neutral, so an iOS view can be added
// later without touching anything below this layer.
#if os(macOS)

/// White pages: who a callsign belongs to, and how this station knows.
///
/// Provenance is on the face of the row rather than buried in a tooltip,
/// because it is the thing that decides whether an entry can be trusted. A
/// name someone typed at the prompt and a home BBS guessed from a message
/// header look identical once you write them both down as text.
struct BBSDirectoryPane: View {
    @ObservedObject var service: BBSService

    @State private var selection: String?
    @State private var drafts: [WhitePagesEntry.Key: String] = [:]
    @FocusState private var editing: WhitePagesEntry.Key?
    @State private var newCallsign = ""
    @State private var isLookingUp = false

    var body: some View {
        VStack(spacing: 0) {
            if !service.suggestions.isEmpty {
                suggestions
                Divider()
            }
            HSplitView {
                list.frame(minWidth: 240, idealWidth: 300)
                detail.frame(minWidth: 320)
            }
        }
    }

    /// Facts spotted in BBS sessions the operator had, waiting to be accepted.
    ///
    /// Offered rather than applied, and each with the line it was parsed from:
    /// this is a guess about another system's display format, and an operator
    /// deciding whether to trust it needs to see what was actually read.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(BBSDirectorySuggestions.headline(service.suggestions),
                      systemImage: "sparkle.magnifyingglass")
                    .font(.callout)
                Spacer()
                Button("Add All") { service.acceptAllSuggestions() }
                    .controlSize(.small)
                Button("Dismiss All") { service.dismissAllSuggestions() }
                    .controlSize(.small)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(service.suggestions) { candidate in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(candidate.callsign) · \(candidate.key.label): "
                                     + candidate.value)
                                    .font(.callout)
                                Text(candidate.evidence)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Add") { service.acceptSuggestion(candidate) }
                                .controlSize(.small)
                            Button {
                                service.dismissSuggestion(candidate)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .frame(maxHeight: 140)

            Text("Read from sessions you opened — nothing was asked of anyone. "
                 + "Recorded as worked-out-from-traffic, so it never overwrites "
                 + "what somebody told you.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.bar)
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            if service.directory.isEmpty {
                empty
            } else {
                List(service.directory, selection: $selection) { entry in
                    row(entry).tag(entry.callsign)
                }
                .listStyle(.inset)
            }

            Divider()
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    TextField("Add callsign", text: $newCallsign)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(addEntry)
                    Button("Add", action: addEntry)
                        .disabled(newCallsign.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: 6) {
                    Button {
                        Task {
                            isLookingUp = true
                            await service.fillDirectoryFromLicences(for: knownCallsigns)
                            isLookingUp = false
                        }
                    } label: {
                        Label("Look Up Callsigns", systemImage: "magnifyingglass")
                    }
                    .controlSize(.small)
                    .disabled(isLookingUp || knownCallsigns.isEmpty)
                    .help("Looks up everyone here and everyone who has called, and fills "
                          + "empty names and locations from the licence record. Anything a "
                          + "caller told you is left alone.\n\nNeeds \"Look up callsigns "
                          + "online\" in Settings → Winlink.")
                    if isLookingUp {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            }
            .padding(8)
        }
    }

    private func row(_ entry: WhitePagesEntry) -> some View {
        let model = BBSDirectoryRowModel.make(entry)
        return VStack(alignment: .leading, spacing: 2) {
            Text(model.callsign)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.medium)
            Text(model.subtitle)
                .font(.caption)
                .foregroundStyle(model.hasName ? .secondary : .tertiary)
        }
        .padding(.vertical, 2)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("Directory empty").font(.callout).foregroundStyle(.secondary)
            Text("Callers fill this in themselves with N, NQ, NH and NZ "
                 + "at the prompt. You can also add someone here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = service.directory.first(where: { $0.callsign == selection }) {
            Form {
                Section {
                    ForEach(WhitePagesEntry.Key.allCases, id: \.self) { key in
                        field(key, entry: entry)
                    }
                } header: {
                    Text(entry.callsign).font(.system(.title3, design: .monospaced))
                } footer: {
                    if let updated = entry.lastUpdated {
                        Text("Last changed \(updated.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Remove \(entry.callsign) from the directory", role: .destructive) {
                        service.sysopDeleteDirectoryEntry(callsign: entry.callsign)
                        selection = nil
                    }
                } footer: {
                    Text("Callers can put themselves back at any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .onChange(of: editing) { _, focused in
                guard let focused else { return }
                drafts[focused] = entry.value(focused) ?? ""
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text("Select a callsign").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func field(_ key: WhitePagesEntry.Key, entry: WhitePagesEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // A draft shadows the stored value only while this field is being
            // edited. Letting it shadow always meant a value fetched after the
            // drafts were seeded — a licence lookup, a caller telling us their
            // name — showed as "not on file" while the list row beside it
            // showed the truth.
            TextField(key.label,
                      text: Binding(
                        get: { editing == key ? (drafts[key] ?? "") : (entry.value(key) ?? "") },
                        set: { drafts[key] = $0 }),
                      prompt: Text("not on file"))
                .focused($editing, equals: key)
                .onSubmit {
                    service.sysopSetDirectoryField(
                        callsign: entry.callsign, key: key, value: drafts[key] ?? "")
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
            }
        }
    }

    /// Everyone worth filling in: the directory itself, plus anyone who has
    /// called — a caller with no entry is exactly who this is for.
    private var knownCallsigns: [String] {
        Array(Set(service.directory.map(\.callsign)
                  + service.calls.map { BBSMessage.baseCall($0.callsign) }))
    }

    private func addEntry() {
        let call = newCallsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else { return }
        // An entry with no fields would not survive a reload — the store holds
        // fields, not empty shells. Seeding the name with the callsign gives
        // the operator something to edit, and reads honestly until they do.
        service.sysopSetDirectoryField(callsign: call, key: .name, value: call)
        newCallsign = ""
        selection = BBSMessage.baseCall(call)
    }
}
#endif
