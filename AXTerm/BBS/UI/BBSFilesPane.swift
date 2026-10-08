//
//  BBSFilesPane.swift
//  AXTerm
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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

    @State private var selectedArea: String?
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
            if library.index.areas.isEmpty {
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
                List(library.index.areas, selection: $selectedArea) { area in
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
                        Button("Stop sharing \(area.name)", role: .destructive) {
                            library.removeArea(name: area.name)
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
            fileTable
            Divider()
            fileFooter
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
            Table(files) {
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
                TableColumn("Description") { file in
                    Text(file.about.isEmpty ? "—" : file.about)
                        .foregroundStyle(file.about.isEmpty ? .tertiary : .primary)
                        .onTapGesture {
                            draftAbout = file.about
                            editing = file
                        }
                }
            }
            .contextMenu(forSelectionType: BBSSharedFile.ID.self) { _ in } primaryAction: { ids in
                guard let id = ids.first,
                      let file = files.first(where: { $0.id == id }) else { return }
                draftAbout = file.about
                editing = file
            }
        }
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
