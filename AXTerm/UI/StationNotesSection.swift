import SwiftUI
import PhotosUI

/// What the operator knows that no directory does.
///
/// Separate from the rest of the profile because everything else there is
/// *observed* — measured, looked up, inferred — and this is the one part the
/// operator writes. Keeping it visually distinct keeps that line clear: a note
/// saying "answers on 145.050 only" is a claim by the operator, not a
/// measurement by the station.
struct StationNotesSection: View {

    let callsign: String
    let store: StationNoteStore
    /// Shared with settings so a height typed here reads back in the same
    /// unit the operator chose there.
    @Binding var heightUnitIsFeet: Bool

    @State private var body_ = ""
    @State private var loaded = false
    @State private var attachments: [StationAttachment] = []
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var errorText: String?
    @State private var previewData: Data?
    @FocusState private var editing: Bool
    /// Nil until the operator records one. Distinct from zero, which is a
    /// real height for a handheld at street level.
    @State private var antennaHeightMetres: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Notes", systemImage: "square.and.pencil")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextEditor(text: $body_)
                .focused($editing)
                .font(.callout)
                .frame(minHeight: 88)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(platform: .platformTextBackground),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if body_.isEmpty {
                        Text("Antenna, hours, who runs it, which frequency actually answers\u{2026}")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                // Saved when the operator looks away rather than on every
                // keystroke: a note is a paragraph, not a live field, and a
                // write per character would thrash the database.
                .onChange(of: editing) { _, isEditing in
                    if !isEditing { save() }
                }

            antennaHeightRow

            if !attachments.isEmpty { attachmentList }

            HStack(spacing: 10) {
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    Label("Add Photo", systemImage: "photo.badge.plus")
                        .font(.caption)
                }
                Spacer()
                if editing {
                    Button("Save") {
                        editing = false
                        save()
                    }
                    .font(.caption.weight(.medium))
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Notes and photos stay on this device. They are the operator's own knowledge, not something measured, so nothing here affects routing or link quality.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(platform: .platformCardBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: callsign) { load() }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task { await attach(item) }
        }
        .sheet(isPresented: Binding(
            get: { previewData != nil },
            set: { if !$0 { previewData = nil } })) {
            if let previewData, let image = PlatformImage(data: previewData) {
                AttachmentPreview(image: image) { self.previewData = nil }
            }
        }
    }

    private var attachmentList: some View {
        VStack(spacing: 6) {
            ForEach(attachments) { attachment in
                HStack(spacing: 8) {
                    Image(systemName: attachment.kind == .photo ? "photo" : "doc")
                        .foregroundStyle(.secondary)
                    Button {
                        previewData = try? store.attachmentData(id: attachment.id)
                    } label: {
                        Text(attachment.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    Text(WinlinkExchangeStatus.compact(attachment.byteCount))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Button {
                        remove(attachment)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    /// The one fact about a remote station that changes a terrain verdict.
    ///
    /// Worth a field of its own rather than a line in the note, because the
    /// forecast reads it: an antenna height buried in prose is knowledge the
    /// app cannot use. Absent by default and explicitly clearable, because a
    /// guess stored as a fact is worse than no answer.
    private var antennaHeightRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let height = antennaHeightMetres {
                HStack(spacing: 8) {
                    AntennaHeightField(
                        title: "Antenna height",
                        metres: Binding(get: { height },
                                        set: { setHeight($0) }),
                        isFeet: $heightUnitIsFeet)
                    Button {
                        setHeight(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Forget this height. Terrain forecasts go back to the assumption in settings.")
                }
                .help("Metres above the ground beneath the antenna, used by terrain forecasts for every path this station appears in. Height decides Fresnel clearance; gain and antenna type do not enter this calculation.")
            } else {
                Button {
                    setHeight(10)
                } label: {
                    Label("Record antenna height", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .help("Terrain forecasts currently assume a height for this station. If you know the real one, recording it here makes every forecast on paths to this station worth trusting \u{2014} height is what decides Fresnel clearance.")
            }
        }
    }

    private func setHeight(_ metres: Double?) {
        antennaHeightMetres = metres
        do {
            try store.saveAntennaHeight(callsign: callsign, metres: metres, now: Date())
            errorText = nil
        } catch {
            errorText = "Could not save the antenna height: \(error.localizedDescription)"
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        body_ = (try? store.note(for: callsign))?.body ?? ""
        attachments = (try? store.attachments(for: callsign)) ?? []
        antennaHeightMetres = (try? store.antennaHeight(for: callsign)) ?? nil
    }

    private func save() {
        do {
            try store.saveNote(callsign: callsign, body: body_, now: Date())
            errorText = nil
        } catch {
            errorText = "Could not save the note: \(error.localizedDescription)"
        }
    }

    private func attach(_ item: PhotosPickerItem) async {
        defer { pickedPhoto = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            errorText = "That photo could not be read."
            return
        }
        do {
            let name = "Photo \(attachments.filter { $0.kind == .photo }.count + 1)"
            let stored = try store.addAttachment(
                callsign: callsign, kind: .photo, name: name, data: data, now: Date())
            attachments.insert(stored, at: 0)
            errorText = nil
        } catch SQLiteStationNoteStore.StoreError.attachmentTooLarge(let size) {
            // Named plainly rather than failing silently: the operator picked
            // something and deserves to know why it did not stick.
            errorText = "That photo is \(WinlinkExchangeStatus.compact(size)), over the \(WinlinkExchangeStatus.compact(SQLiteStationNoteStore.maximumAttachmentBytes)) limit for a station note."
        } catch {
            errorText = "Could not attach that photo: \(error.localizedDescription)"
        }
    }

    private func remove(_ attachment: StationAttachment) {
        try? store.deleteAttachment(id: attachment.id)
        attachments.removeAll { $0.id == attachment.id }
    }
}

/// Full-size look at an attached photo.
private struct AttachmentPreview: View {
    let image: PlatformImage
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            #if os(macOS)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
            #else
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
            #endif
        }
        .frame(minWidth: 320, minHeight: 320)
    }
}
