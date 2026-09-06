//
//  BBSFilesPane.swift
//  AXTerm
//

import SwiftUI
import UniformTypeIdentifiers

// The mailbox UI is macOS-only, like the window layout it lives in. The shell,
// the store and the service are platform-neutral, so an iOS view can be added
// later without touching anything below this layer.
#if os(macOS)

/// What callers can download, and what it costs them.
///
/// The operator's view of the same catalogue callers see, with the column that
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
    @State private var showingPicker = false
    @State private var pendingURL: URL?
    @State private var newAreaName = ""
    @State private var newAreaAbout = ""
    @State private var showingInboxPicker = false

    var body: some View {
        HSplitView {
            areaList.frame(minWidth: 220, idealWidth: 260)
            fileList.frame(minWidth: 380)
        }
        .fileImporter(isPresented: $showingInboxPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                library.setInbox(url: url)
            }
        }
        .fileImporter(isPresented: $showingPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                pendingURL = url
                newAreaName = BBSFileArea.normalize(url.lastPathComponent)
            }
        }
        .sheet(item: $editing) { file in
            descriptionSheet(file)
        }
        .sheet(isPresented: Binding(get: { pendingURL != nil },
                                    set: { if !$0 { pendingURL = nil } })) {
            newAreaSheet
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .font(.system(.callout, design: .monospaced))
                            .fontWeight(.medium)
                        Text(model.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !model.about.isEmpty {
                            Text(model.about).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(area.name)
                    .contextMenu {
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
                    showingPicker = true
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
                if let inbox = library.inboxName {
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
                        Button("Change…") { showingInboxPicker = true }
                            .controlSize(.small)
                    }
                    // Said plainly: an operator who assumes uploads are
                    // immediately downloadable has assumed their station will
                    // redistribute whatever anyone sends it.
                    Text("Uploads land here and are **not** shared. Move one into an "
                         + "area above to offer it to callers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Choose Where Uploads Land…") { showingInboxPicker = true }
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

    @ViewBuilder
    private var fileList: some View {
        let files = selectedArea.map { library.index.files(in: $0) } ?? library.index.files
        if files.isEmpty {
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
            TextField("Description", text: $draftAbout)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { editing = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    library.setDescription(area: file.area, name: file.name, about: draftAbout)
                    editing = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private var newAreaSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share a Folder").font(.headline)
            if let pendingURL {
                Text(pendingURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            TextField("Area name", text: $newAreaName)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Text("What callers type: F \(newAreaName.isEmpty ? "NAME" : newAreaName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("What is in it", text: $newAreaAbout)
                .textFieldStyle(.roundedBorder)
            Text("Files are shared one level deep. Subfolders, hidden files and "
                 + "symlinks are skipped, and so is anything over "
                 + "\(BBSFileIndex.size(BBSFileLibrary.defaultMaxFileBytes)).")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") { pendingURL = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Share") {
                    if let url = pendingURL {
                        library.addArea(name: newAreaName, about: newAreaAbout, url: url)
                    }
                    pendingURL = nil
                    newAreaName = ""
                    newAreaAbout = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newAreaName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
#endif
