import SwiftUI

/// One session, in full.
struct SessionHistoryDetail: View {

    let session: TerminalSession
    let store: TerminalSessionStoring?
    var onOpenCallsign: ((String) -> Void)?
    var onChanged: () -> Void

    @State private var tagDraft = ""
    @State private var note = ""
    @State private var loadedNoteFor: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                tagEditor
                noteEditor
                transcript
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: session.id) {
            // Per session, or an edit to one note follows the operator to the
            // next session they click.
            note = session.note ?? ""
            tagDraft = ""
            loadedNoteFor = session.id
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(session.correspondent) { onOpenCallsign?(session.correspondent) }
                    .buttonStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(onOpenCallsign == nil
                                     ? AnyShapeStyle(.primary)
                                     : AnyShapeStyle(.tint))
                OutcomeBadge(outcome: session.outcome)
            }
            Text(detailLine)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(trafficLine)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// The path, spelled out, because it is the thing that makes a session
    /// worth looking back at: the same station over a different path is a
    /// different fact.
    private var detailLine: String {
        var parts = [session.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let duration = session.duration, duration >= 1 {
            parts.append(SessionHistoryRow.durationText(duration))
        }
        if session.relayDestination != nil {
            parts.append("through \(session.remote)")
        }
        if !session.via.isEmpty {
            parts.append("via " + session.via.joined(separator: " \u{2192} "))
        }
        parts.append(session.transport)
        return parts.joined(separator: " \u{00B7} ")
    }

    private var trafficLine: String {
        "\(session.framesSent.formatted()) sent, "
            + "\(session.framesReceived.formatted()) received \u{00B7} "
            + "\(session.bytesSent.formatted()) / \(session.bytesReceived.formatted()) bytes"
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(session.tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text(tag)
                        Button {
                            save(tags: session.tags.filter { $0 != tag })
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                }
                TextField("Add tag", text: $tagDraft)
                    .frame(maxWidth: 140)
                    .onSubmit {
                        guard !tagDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        save(tags: session.tags + [tagDraft])
                        tagDraft = ""
                    }
            }
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Note").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $note)
                .frame(minHeight: 60)
                .font(.callout)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.1)))
                // Saved when focus leaves rather than on every keystroke: a
                // write per character would put the database on the typing
                // path for no benefit.
                .onSubmit { saveNote() }
            Button("Save note") { saveNote() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)
                .disabled(note == (session.note ?? ""))
        }
    }

    @ViewBuilder
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Transcript")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !session.transcript.isEmpty {
                    Button("Copy") {
                        ClipboardWriter.copy(session.transcript)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
                }
            }
            if session.transcript.isEmpty {
                Text("Nothing was exchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(session.transcript)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func save(tags: [String]) {
        try? store?.setTags(tags, for: session.id)
        onChanged()
    }

    private func saveNote() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        try? store?.setNote(trimmed.isEmpty ? nil : trimmed, for: session.id)
        onChanged()
    }
}
