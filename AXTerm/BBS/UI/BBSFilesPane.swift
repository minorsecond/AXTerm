//
//  BBSFilesPane.swift
//  AXTerm
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import QuickLook

// The Mac pane. The iOS screens are BBSAreaListScreen and BBSFileListScreen;
// what both decide lives in BBSMailboxModels and BBSFilePicking.
#if os(macOS)

/// What callers can download, and what it costs them.
///
/// The operator's view of the same catalog callers see, with the column that
/// decides everything — time on the air — shown the same way here as it is at
/// the prompt. A 2 MB file looks harmless in a Finder window and is four hours
/// of a shared frequency.
struct BBSFilesPane: View {
    @ObservedObject var library: BBSFileLibrary
    @ObservedObject var settings: BBSSettings
    /// Same figure the shell quotes callers, so the two never disagree.
    let bytesPerSecond: Double

    /// The sidebar's selection: an area's name, or `uploadsTag`.
    @State private var selection: String?
    /// The uploads table's selection, by file name.
    @State private var uploadSelection = Set<BBSUpload.ID>()
    @State private var previewURL: URL?
    /// Uploads waiting for the operator to confirm Move to Trash.
    @State private var trashing: [String] = []
    /// The shared file list's selection, and shared files waiting for the
    /// operator to confirm Move to Trash (finding 3).
    @State private var fileSelection = Set<BBSSharedFile.ID>()
    @State private var trashingShared: [BBSSharedFile] = []
    @State private var editingTrusted = false

    private static let uploadsTag = BBSUpload.listTag
    private var selectedArea: String? { selection == Self.uploadsTag ? nil : selection }
    private var showingUploads: Bool { selection == Self.uploadsTag }
    @State private var editing: BBSSharedFile?
    @State private var draftAbout = ""
    /// What the one importer is choosing, or nil when it is closed. See
    /// `BBSFilePickPurpose` for why there is only one.
    @State private var picker = BBSFilePicker()
    @State private var pendingURL: URL?
    @State private var newAreaName = ""
    @State private var newAreaAbout = ""
    /// What happened to the last files added, until the operator dismisses it.
    @State private var addMessage: String?
    @State private var dropTargeted = false
    /// Photos waiting for the operator to pick their size.
    @State private var sizingPhotos: [BBSPendingPhoto] = []
    /// The area photos from the library go into, while the picker is up.
    @State private var photoArea: String?
    @State private var photoSelection: [PhotosPickerItem] = []

    var body: some View {
        HSplitView {
            areaList.frame(minWidth: 220, idealWidth: 260)
            fileList.frame(minWidth: 380)
        }
        .fileImporter(isPresented: Binding(get: { picker.isPresented },
                                           set: { if !$0 { picker.panelClosed() } }),
                      allowedContentTypes: picker.contentTypes,
                      allowsMultipleSelection: picker.allowsMultipleSelection) { result in
            let purpose = picker.finish()
            guard let purpose, case .success(let urls) = result else { return }
            switch BBSFilePick.apply(purpose, urls: urls, library: library) {
            case .nameNewArea(let url):
                pendingURL = url
                newAreaName = BBSFileArea.normalize(url.lastPathComponent)
            case .finished(let message):
                addMessage = message
            case .sizePhotos(let photos, let message):
                addMessage = message
                sizingPhotos = photos
            }
        }
        .sheet(isPresented: Binding(get: { !sizingPhotos.isEmpty },
                                    set: { if !$0 { sizingPhotos = [] } })) {
            photoSizeSheet
        }
        .photosPicker(isPresented: Binding(get: { photoArea != nil },
                                           set: { if !$0 && photoSelection.isEmpty { photoArea = nil } }),
                      selection: $photoSelection, maxSelectionCount: 20, matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty, let area = photoArea else { return }
            photoSelection = []
            photoArea = nil
            Task { await addLibraryPhotos(items, to: area) }
        }
        .sheet(item: $editing) { file in
            descriptionSheet(file)
        }
        .sheet(isPresented: $editingTrusted) {
            BBSTrustedCallersEditor(settings: settings, station: settings.callsign)
        }
        .sheet(isPresented: Binding(get: { pendingURL != nil },
                                    set: { if !$0 { pendingURL = nil } })) {
            newAreaSheet
        }
    }

    /// Photos from the library: small ones go straight in, the rest wait
    /// for their size in the same sheet as photos from Files.
    private func addLibraryPhotos(_ items: [PhotosPickerItem], to area: String) async {
        let loaded = await BBSLibraryPhotos.load(items)
        let result = BBSPhotoIntake.addFromLibrary(loaded, to: area, library: library)
        addMessage = BBSAddFilesSummary.message(for: result.outcomes, area: area)
        sizingPhotos = result.waiting
    }

    private var photoSizeSheet: some View {
        BBSPhotoIntakeSheet(photos: sizingPhotos) { photo, prepared in
            BBSPhotoIntake.add(photo, as: prepared, library: library)
        } finish: { outcomes in
            let area = sizingPhotos.first?.area ?? ""
            let lines = [addMessage, BBSAddFilesSummary.message(for: outcomes, area: area)].compactMap { $0 }
            addMessage = lines.isEmpty ? nil : lines.joined(separator: "\n")
            sizingPhotos = []
        }
    }

    // MARK: - Areas

    private var areaList: some View {
        VStack(spacing: 0) {
            if library.index.areas.isEmpty && !library.hasInbox {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("Nothing shared").font(.callout).foregroundStyle(.secondary)
                    Text("Share a folder and callers can list it with F "
                         + "and fetch from it with D.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    if !library.index.areas.isEmpty {
                        Section("Shared") {
                            ForEach(library.index.areas) { area in
                                let model = BBSAreaRowModel.make(
                                    area, files: library.index.files(in: area.name))
                                let missing = library.unreachableAreas.contains(area.name)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(model.name)
                                            .font(.system(.callout, design: .monospaced))
                                            .fontWeight(.medium)
                                        if missing {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                                .accessibilityLabel("Folder missing")
                                        }
                                        if area.acceptsTrustedUploads {
                                            Image(systemName: "tray.and.arrow.down")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .help("Trusted callers can upload into \(area.name)")
                                                .accessibilityLabel("Takes uploads from trusted callers")
                                        }
                                    }
                                    if missing {
                                        // Said on the row, with the fix beside it: an
                                        // area that serves nothing because its folder
                                        // moved looks exactly like an empty one otherwise.
                                        Text("Folder can no longer be found")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                        Button("Choose Folder Again…") {
                                            picker.begin(.relocate(area: area.name))
                                        }
                                        .controlSize(.small)
                                    } else {
                                        Text(model.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !model.about.isEmpty {
                                        Text(model.about).font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.vertical, 2)
                                .tag(area.name)
                                .contextMenu {
                                    if !missing {
                                        Button("Add Files to \(area.name)…") {
                                            picker.begin(.addFiles(area: area.name))
                                        }
                                        Button("Add Photos to \(area.name)…") {
                                            photoArea = area.name
                                        }
                                    }
                                    Button("Choose Folder Again…") {
                                        picker.begin(.relocate(area: area.name))
                                    }
                                    Divider()
                                    Toggle("Trusted Callers Can Upload Here", isOn: Binding(
                                        get: { area.acceptsTrustedUploads },
                                        set: { library.setAcceptsTrustedUploads($0, area: area.name) }))
                                    Divider()
                                    Button("Stop sharing \(area.name)", role: .destructive) {
                                        library.removeArea(name: area.name)
                                    }
                                }
                            }
                        }
                    }
                    if library.hasInbox {
                        Section("Received") {
                            uploadsRow.tag(Self.uploadsTag)
                        }
                    }
                }
                .listStyle(.inset)
            }

            if let error = library.lastScanError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Button {
                    picker.begin(.shareFolder)
                } label: {
                    Label("Share a Folder…", systemImage: "plus")
                }
                Spacer()
                Button {
                    library.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan for files added or removed since AXTerm started")
            }
            .padding(8)

            Divider()
            uploads
        }
    }

    /// Accepting files is a separate decision from sharing them, and it lives
    /// here rather than in Settings so the switch is beside the thing it
    /// fills. An operator can see the inbox growing without going looking.
    private var uploads: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Let callers send me files", isOn: $settings.acceptUploads)
                .font(.callout)

            if settings.acceptUploads {
                if library.inboxUnreachable {
                    Label("The upload folder can no longer be found, so uploads are "
                          + "refused until you choose it again.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Choose Upload Folder Again…") { picker.begin(.uploadInbox) }
                        .controlSize(.small)
                } else if let inbox = library.inboxName {
                    let box = BBSUploadInboxModel.make(count: library.inboxCount,
                                                       bytes: library.inboxBytes,
                                                       quotaBytes: settings.uploadQuotaBytes)
                    HStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.down").font(.caption)
                        Text(inbox).font(.caption).lineLimit(1)
                        // The quota is stated with the usage rather than
                        // surfaced as an error later: an operator whose uploads
                        // start being refused cannot tell a full inbox from a
                        // broken transfer.
                        Text("· " + box.label)
                            .font(.caption)
                            .foregroundStyle(box.isFull ? Color.orange : Color.secondary)
                        Spacer()
                        Button("Change…") { picker.begin(.uploadInbox) }
                            .controlSize(.small)
                    }
                    // Said plainly: an operator who assumes uploads are
                    // immediately downloadable has assumed their station will
                    // redistribute whatever anyone sends it.
                    // One literal: Text renders Markdown only from a string
                    // literal, and a concatenation showed the asterisks
                    // (smoke run issue 68).
                    Text("Uploads land here and are **not** shared. Move one into an area above to offer it to callers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Choose Where Uploads Land…") { picker.begin(.uploadInbox) }
                        .controlSize(.small)
                    Text("Uploads are refused until you pick a folder.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Text("Largest file").font(.caption)
                    Picker("", selection: $settings.maxUploadBytes) {
                        ForEach(BBSUploadSizeOption.options(
                            including: settings.maxUploadBytes)) { option in
                            Text(option.label).tag(option.bytes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                    Text("· \(BBSFileIndex.duration(bytes: settings.maxUploadBytes, bytesPerSecond: bytesPerSecond)) on the air")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Who may upload straight into an area that allows it
                // (home retest finding 11).
                HStack(spacing: 4) {
                    Text("Trusted").font(.caption)
                    Text(BBSTrust.summary(station: settings.callsign, list: settings.trustedCallers))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button("Edit…") { editingTrusted = true }
                        .controlSize(.small)
                }
                .help("Callers who can upload straight into an area you switch to take their uploads, "
                      + "from that area's menu")
            }
        }
        .padding(8)
    }

    // MARK: - Files

    /// The selected area, when files can be added to it: selected, and its
    /// folder found at the last scan.
    private var addableArea: String? {
        guard let selectedArea, !library.unreachableAreas.contains(selectedArea) else { return nil }
        return selectedArea
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            if showingUploads {
                uploadsTable
                Divider()
                uploadsFooter
            } else {
                fileTable
                Divider()
                fileFooter
            }
        }
        // Drop files from Finder onto the list to share them in the selected
        // area. Copied, so the originals stay where they were.
        .onDrop(of: BBSFileDrop.acceptedTypes, isTargeted: $dropTargeted) { providers in
            guard let area = addableArea else { return false }
            BBSFileDrop.add(providers, to: area, library: library) { message, photos in
                addMessage = message
                sizingPhotos = photos
            }
            return true
        }
        .overlay {
            if dropTargeted, addableArea != nil {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private var fileFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let addMessage {
                HStack(alignment: .top, spacing: 6) {
                    Text(addMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        self.addMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Dismiss")
                }
            }
            HStack {
                Button {
                    if let area = addableArea { picker.begin(.addFiles(area: area)) }
                } label: {
                    Label("Add Files…", systemImage: "doc.badge.plus")
                }
                .disabled(addableArea == nil)
                Button {
                    photoArea = addableArea
                } label: {
                    Label("Add Photos…", systemImage: "photo.badge.plus")
                }
                .disabled(addableArea == nil)
                .help("Choose photos from your Photos library. Each is sized before callers see it.")
                Text(addableArea.map { "Copies files into \($0)'s folder. You can also drop them here." }
                     ?? "Select an area to add files to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private var fileTable: some View {
        let files = selectedArea.map { library.index.files(in: $0) } ?? library.index.files
        if let selectedArea, library.unreachableAreas.contains(selectedArea) {
            VStack(spacing: 6) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
                Text("\(selectedArea)'s folder can no longer be found")
                    .foregroundStyle(.secondary)
                Text("Callers see this area as empty until you choose its folder again.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                Button("Choose Folder Again…") { picker.begin(.relocate(area: selectedArea)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if files.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text(selectedArea == nil ? "Select an area" : "This area has no files")
                    .foregroundStyle(.secondary)
                if selectedArea != nil {
                    Text("Files over \(BBSFileIndex.size(BBSFileLibrary.defaultMaxFileBytes)), "
                         + "hidden files and symlinks are skipped.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(files, selection: $fileSelection) {
                TableColumn("Name") { file in
                    HStack(spacing: 5) {
                        Image(systemName: file.isText ? "doc.text" : "doc")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(file.name).font(.system(.body, design: .monospaced))
                    }
                }
                TableColumn("Size") { file in
                    Text(BBSFileRowModel.make(file, bytesPerSecond: bytesPerSecond).size)
                        .monospacedDigit()
                }
                .width(60)
                TableColumn("On air") { file in
                    let model = BBSFileRowModel.make(file, bytesPerSecond: bytesPerSecond)
                    Text(model.airtime)
                        .monospacedDigit()
                        // The number that decides whether a caller should ask
                        // for this at all.
                        .foregroundStyle(model.isLongTransfer ? Color.orange : Color.primary)
                }
                .width(70)
                TableColumn("Modified") { file in
                    Text(file.modifiedAt, format: .dateTime.year().month(.abbreviated).day())
                        .monospacedDigit()
                        .help(file.modifiedAt.formatted(date: .complete, time: .shortened))
                }
                .width(min: 90, ideal: 100)
                // Who uploaded it, for a file that came from a caller; never
                // shown to callers (finding 2).
                TableColumn("From") { file in
                    if let provenance = file.provenance {
                        Text(provenance.from)
                            .font(.system(.body, design: .monospaced))
                            .help(provenance.help(inbox: library.inboxName ?? "the inbox"))
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 70, ideal: 90)
                // No tap gesture here: it took the click, and rows could not
                // be selected (retest 2026-10-10, finding 3). Double-click or
                // the menu edits the description.
                TableColumn("Description") { file in
                    Text(file.about.isEmpty ? "—" : file.about)
                        .foregroundStyle(file.about.isEmpty ? .tertiary : .primary)
                }
            }
            .contextMenu(forSelectionType: BBSSharedFile.ID.self) { ids in
                sharedFileMenu(for: files.filter { ids.contains($0.id) })
            } primaryAction: { ids in
                guard let id = ids.first,
                      let file = files.first(where: { $0.id == id }) else { return }
                draftAbout = file.about
                editing = file
            }
            .quickLookPreview($previewURL)
            .confirmationDialog(sharedTrashTitle,
                                isPresented: Binding(get: { !trashingShared.isEmpty },
                                                     set: { if !$0 { trashingShared = [] } })) {
                Button("Move to Trash", role: .destructive) {
                    let doomed = trashingShared
                    trashingShared = []
                    trashSharedFiles(doomed)
                }
                Button("Cancel", role: .cancel) { trashingShared = [] }
            } message: {
                Text("Callers will no longer see \(trashingShared.count == 1 ? "it" : "them") in "
                     + "\(trashingShared.first?.area ?? "the area"). You can put "
                     + "\(trashingShared.count == 1 ? "it" : "them") back from the Trash in Finder.")
            }
        }
    }

    // MARK: - Shared file actions (finding 3)

    private var sharedTrashTitle: String {
        trashingShared.count == 1 ? "Move \(trashingShared[0].name) to the Trash?"
            : "Move \(trashingShared.count) files to the Trash?"
    }

    @ViewBuilder
    private func sharedFileMenu(for chosen: [BBSSharedFile]) -> some View {
        if !chosen.isEmpty {
            Button("Open") { chosen.compactMap(library.sharedFileURL).forEach { NSWorkspace.shared.open($0) } }
            Button("Quick Look") { previewURL = chosen.first.flatMap(library.sharedFileURL) }
            Button("Show in Finder") {
                let urls = chosen.compactMap(library.sharedFileURL)
                if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            }
            if chosen.count == 1, let file = chosen.first {
                Button("Edit Description\u{2026}") {
                    draftAbout = file.about
                    editing = file
                }
            }
            Divider()
            Button("Move to Trash\u{2026}", role: .destructive) { trashingShared = chosen }
        }
    }

    private func trashSharedFiles(_ doomed: [BBSSharedFile]) {
        var failed: [String] = []
        for file in doomed {
            do { try library.trashSharedFile(file) } catch { failed.append(error.localizedDescription) }
        }
        fileSelection = []
        addMessage = failed.isEmpty ? nil : failed.joined(separator: " ")
    }

    // MARK: - Uploads

    /// The Received row: where uploads land, and how many are waiting.
    private var uploadsRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(library.inboxName ?? "Uploads")
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.medium)
            } icon: {
                Image(systemName: "tray.and.arrow.down")
            }
            Text(library.inboxCount == 0 ? "No uploads"
                 : "\(library.inboxCount) \(library.inboxCount == 1 ? "upload" : "uploads") · not shared")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .badge(library.inboxCount)
    }

    /// What callers sent, newest first, with who sent it (home retest
    /// finding 8). Before this the window showed only a count, and an
    /// upload took Finder to find.
    @ViewBuilder
    private var uploadsTable: some View {
        VStack(spacing: 0) {
            if let arriving = library.arriving {
                BBSArrivingUploadRow(arriving: arriving)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
            }
            uploadsList
        }
    }

    @ViewBuilder
    private var uploadsList: some View {
        if library.uploads.isEmpty && library.arriving == nil {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("No uploads").foregroundStyle(.secondary)
                Text("Files callers send land in \(library.inboxName ?? "the upload folder"). "
                     + "They show here as soon as they arrive.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if library.uploads.isEmpty {
            Spacer()
        } else {
            Table(library.uploads, selection: $uploadSelection) {
                TableColumn("Name") { upload in
                    HStack(spacing: 5) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(upload.name).font(.system(.body, design: .monospaced))
                    }
                }
                TableColumn("Size") { upload in
                    Text(BBSFileIndex.size(upload.byteCount)).monospacedDigit()
                }
                .width(60)
                TableColumn("Received") { upload in
                    Text(upload.receivedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .monospacedDigit()
                        .help(upload.receivedAt.formatted(date: .complete, time: .standard))
                }
                .width(min: 110, ideal: 130)
                TableColumn("From") { upload in
                    if let from = upload.from {
                        Text(from).font(.system(.body, design: .monospaced))
                    } else {
                        Text("—")
                            .foregroundStyle(.tertiary)
                            .help("Put in the folder some other way, not sent by a caller")
                    }
                }
                .width(min: 70, ideal: 90)
            }
            .contextMenu(forSelectionType: BBSUpload.ID.self) { names in
                uploadMenu(for: names)
            } primaryAction: { names in
                names.forEach(openUpload)
            }
            .quickLookPreview($previewURL)
            .confirmationDialog(trashTitle, isPresented: Binding(get: { !trashing.isEmpty },
                                                                 set: { if !$0 { trashing = [] } })) {
                Button("Move to Trash", role: .destructive) {
                    let names = trashing
                    trashing = []
                    trashUploads(names)
                }
                Button("Cancel", role: .cancel) { trashing = [] }
            } message: {
                Text("Callers never saw \(trashing.count == 1 ? "it" : "them"). "
                     + "You can put \(trashing.count == 1 ? "it" : "them") back from the Trash in Finder.")
            }
        }
    }

    private var trashTitle: String {
        trashing.count == 1 ? "Move \(trashing[0]) to the Trash?" : "Move \(trashing.count) uploads to the Trash?"
    }

    @ViewBuilder
    private func uploadMenu(for names: Set<BBSUpload.ID>) -> some View {
        let sorted = names.sorted()
        if !sorted.isEmpty {
            Button("Open") { sorted.forEach(openUpload) }
            Button("Quick Look") { previewURL = sorted.first.flatMap(library.uploadURL(named:)) }
            Button("Show in Finder") {
                let urls = sorted.compactMap(library.uploadURL(named:))
                if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            }
            Divider()
            Menu("Move to Area") {
                ForEach(library.index.areas.filter { !library.unreachableAreas.contains($0.name) }) { area in
                    Button(area.name) { moveUploads(sorted, to: area.name) }
                }
            }
            .disabled(library.index.areas.isEmpty)
            Divider()
            Button("Move to Trash…", role: .destructive) { trashing = sorted }
        }
    }

    private func openUpload(_ name: String) {
        if let url = library.uploadURL(named: name) { NSWorkspace.shared.open(url) }
    }

    private func moveUploads(_ names: [String], to area: String) {
        let outcomes = names.map { library.moveUpload(named: $0, toArea: area) }
        uploadSelection = []
        addMessage = BBSUploadMoveReport.message(outcomes, area: area)
    }

    private func trashUploads(_ names: [String]) {
        var failed: [String] = []
        for name in names {
            do { try library.trashUpload(named: name) } catch { failed.append(error.localizedDescription) }
        }
        uploadSelection = []
        addMessage = failed.isEmpty ? nil : failed.joined(separator: " ")
    }

    private var uploadsFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let addMessage {
                HStack(alignment: .top, spacing: 6) {
                    Text(addMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        self.addMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Dismiss")
                }
            }
            // One literal, so the Markdown renders (smoke run issue 68).
            Text("Uploads are **not** shared. Move one into an area to offer it to callers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sheets

    private func descriptionSheet(_ file: BBSSharedFile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(file.name).font(.headline)
            // A filename alone tells a caller nothing, and on this link they
            // cannot afford to download one to find out what it is.
            Text("Callers see this beside the file. One line.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Return in the field saves too: a focused text field takes
            // Return before the default button sees it (park rehearsal
            // 2026-10-08).
            TextField("Description", text: $draftAbout)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveDescription(file) }
            HStack {
                Spacer()
                Button("Cancel") { editing = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveDescription(file) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func saveDescription(_ file: BBSSharedFile) {
        library.setDescription(area: file.area, name: file.name, about: draftAbout)
        editing = nil
    }

    private var canShareArea: Bool {
        pendingURL != nil && !newAreaName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func shareArea() {
        guard canShareArea, let url = pendingURL else { return }
        library.addArea(name: newAreaName, about: newAreaAbout, url: url)
        pendingURL = nil
        newAreaName = ""
        newAreaAbout = ""
    }

    private var newAreaSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share a Folder").font(.headline)
            if let pendingURL {
                Text(pendingURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            // Return in either field shares, as the Share button does.
            TextField("Area name", text: $newAreaName)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(shareArea)
            Text("What callers type: F \(newAreaName.isEmpty ? "NAME" : newAreaName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("What is in it", text: $newAreaAbout)
                .textFieldStyle(.roundedBorder)
                .onSubmit(shareArea)
            Text("Files are shared one level deep. Subfolders, hidden files and "
                 + "symlinks are skipped, and so is anything over "
                 + "\(BBSFileIndex.size(BBSFileLibrary.defaultMaxFileBytes)).")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") { pendingURL = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Share", action: shareArea)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canShareArea)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
#endif
