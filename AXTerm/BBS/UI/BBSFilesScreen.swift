//
//  BBSFilesScreen.swift
//  AXTerm
//
//  What callers can download, and what it costs them — on a handheld.
//

#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// Shared areas, and the upload switch beside the folder it fills.
///
/// Uploads live here rather than in Settings for the reason `Docs/PacketBBS.md`
/// §10 gives: putting the switch somewhere the operator cannot see the folder
/// is how a station ends up accepting files into a folder nobody is watching.
struct BBSAreaListScreen: View {

    @ObservedObject var library: BBSFileLibrary
    @ObservedObject var settings: BBSSettings
    /// The same figure the shell quotes callers, so the two never disagree.
    let bytesPerSecond: Double
    @Binding var selection: String?
    var presentation: BBSScreenPresentation = .tab

    /// One importer for every folder this screen picks. Two `.fileImporter`
    /// modifiers on one view behave like two sheets: the last one wins and
    /// the other silently never opens. What the pick is *for* is state.
    @State private var picker = BBSFilePicker()
    @State private var pendingURL: URL?
    @State private var newAreaName = ""
    @State private var newAreaAbout = ""

    var body: some View {
        Group {
            if presentation.ownsNavigation {
                List(selection: $selection) { sections }
                    .listStyle(.insetGrouped)
            } else {
                List { sections }
                    .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    library.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    picker.begin(.shareFolder)
                } label: {
                    Label("Share a Folder", systemImage: "plus")
                }
            }
        }
        .fileImporter(isPresented: Binding(get: { picker.isPresented },
                                           set: { if !$0 { picker.panelClosed() } }),
                      allowedContentTypes: picker.contentTypes,
                      allowsMultipleSelection: picker.allowsMultipleSelection) { result in
            let purpose = picker.finish()
            guard let purpose, case .success(let urls) = result else { return }
            if case .nameNewArea(let url) = BBSFilePick.apply(purpose, urls: urls, library: library) {
                pendingURL = url
                newAreaName = BBSFileArea.normalize(url.lastPathComponent)
            }
        }
        .sheet(isPresented: Binding(get: { pendingURL != nil },
                                    set: { if !$0 { pendingURL = nil } })) {
            NavigationStack { newAreaSheet }
        }
    }

    @ViewBuilder
    private var sections: some View {
        areasSection
        uploadsSection
        if let error = library.lastScanError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Areas

    @ViewBuilder
    private var areasSection: some View {
        Section {
            if library.index.areas.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing shared").font(.callout).foregroundStyle(.secondary)
                    Text("Share a folder and callers can list it with F and fetch from "
                         + "it with D.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(library.index.areas) { area in
                    Group {
                        if presentation.ownsNavigation {
                            areaRow(area).tag(area.name)
                        } else {
                            NavigationLink {
                                BBSFileListScreen(library: library,
                                                  area: area.name,
                                                  bytesPerSecond: bytesPerSecond)
                            } label: {
                                areaRow(area)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Stop Sharing", systemImage: "folder.badge.minus",
                               role: .destructive) {
                            library.removeArea(name: area.name)
                            if selection == area.name { selection = nil }
                        }
                        Button("Choose Folder", systemImage: "folder") {
                            picker.begin(.relocate(area: area.name))
                        }
                    }
                }
            }
        } header: {
            Text("Shared areas")
        } footer: {
            // Said here rather than as an explanation hung on the Rescan
            // button: an explanation with no indicator takes the tap that
            // would have run it.
            Text("Files are shared one level deep. Subfolders, hidden files and symlinks "
                 + "are skipped, and so is anything over "
                 + "\(BBSFileIndex.size(BBSFileLibrary.defaultMaxFileBytes)). Nothing here "
                 + "writes into your folders. Rescan looks for files added or removed "
                 + "since the last look; descriptions live in the database, so nothing "
                 + "you have written is lost by it.")
        }
    }

    private func areaRow(_ area: BBSFileArea) -> some View {
        let model = BBSAreaRowModel.make(area, files: library.index.files(in: area.name))
        let missing = library.unreachableAreas.contains(area.name)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(model.name)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                if missing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Folder missing")
                }
            }
            if missing {
                // On the row, with the fix in its detail and swipe actions:
                // an area whose folder moved looks exactly like an empty one.
                Text("Folder can no longer be found. Swipe to choose it again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
    }

    // MARK: - Uploads

    @ViewBuilder
    private var uploadsSection: some View {
        Section {
            Toggle("Let callers send me files", isOn: $settings.acceptUploads)

            if settings.acceptUploads {
                if library.inboxUnreachable {
                    Button("Choose Upload Folder Again…") { picker.begin(.uploadInbox) }
                    Label("The upload folder can no longer be found, so uploads are refused "
                          + "until you choose it again.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let inbox = library.inboxName {
                    let box = BBSUploadInboxModel.make(count: library.inboxCount,
                                                       bytes: library.inboxBytes,
                                                       quotaBytes: settings.uploadQuotaBytes)
                    HStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(inbox).lineLimit(1)
                            Text(box.label)
                                .font(.caption)
                                .foregroundStyle(box.isFull ? Color.orange : Color.secondary)
                        }
                        Spacer()
                        Button("Change") { picker.begin(.uploadInbox) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    if box.isFull {
                        Label("The inbox is full. Uploads are refused until you move "
                              + "something out of it.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Button("Choose Where Uploads Land…") { picker.begin(.uploadInbox) }
                    Label("Uploads are refused until you pick a folder.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("Largest file", selection: $settings.maxUploadBytes) {
                    ForEach(BBSUploadSizeOption.options(
                        including: settings.maxUploadBytes)) { option in
                        Text(option.label).tag(option.bytes)
                    }
                }
                Text("\(BBSFileIndex.duration(bytes: settings.maxUploadBytes, bytesPerSecond: bytesPerSecond)) on the air at the throughput this link is managing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Uploads")
        } footer: {
            if settings.acceptUploads {
                // Said plainly: an operator who assumes uploads are immediately
                // downloadable has assumed their station will redistribute
                // whatever anyone sends it.
                // One literal, so Text renders the Markdown (smoke run issue 68).
                Text("Uploads land in that folder and are **not** shared. Move one into an area above to offer it to callers.")
            } else {
                Text("Accepting files is a separate decision from sharing them: this one "
                     + "writes to your disk on the say-so of whoever is holding a "
                     + "microphone.")
            }
        }
    }

    // MARK: - Sheet

    private var newAreaSheet: some View {
        Form {
            Section {
                TextField("Area name", text: $newAreaName)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("What is in it", text: $newAreaAbout)
            } header: {
                Text("Area")
            } footer: {
                Text("What callers type: F \(newAreaName.isEmpty ? "NAME" : newAreaName)")
            }

            if let pendingURL {
                Section("Folder") {
                    Text(pendingURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .navigationTitle("Share a Folder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { pendingURL = nil }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Share") {
                    if let url = pendingURL {
                        library.addArea(name: newAreaName, about: newAreaAbout, url: url)
                    }
                    pendingURL = nil
                    newAreaName = ""
                    newAreaAbout = ""
                }
                .disabled(newAreaName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// What is in one area, with the airtime beside every row.
///
/// TIME, not SIZE, is the column that decides anything: "143K" sounds small
/// and is twenty-eight minutes of a frequency somebody else also wants.
struct BBSFileListScreen: View {

    @ObservedObject var library: BBSFileLibrary
    let area: String?
    let bytesPerSecond: Double

    @State private var editing: BBSSharedFile?
    @State private var draftAbout = ""
    /// This screen's one importer: files to add, or the area's folder chosen
    /// again when it has gone missing.
    @State private var picker = BBSFilePicker()
    /// What happened to the last files added, until dismissed.
    @State private var addMessage: String?
    @State private var dropTargeted = false

    private var files: [BBSSharedFile] {
        area.map { library.index.files(in: $0) } ?? []
    }

    private var isMissing: Bool {
        area.map { library.unreachableAreas.contains($0) } ?? false
    }

    var body: some View {
        Group {
            if area == nil {
                BBSEmptyState(
                    systemImage: "folder",
                    title: "Select an area",
                    detail: "Each shared folder is one area. Callers list them with F and "
                        + "fetch a file with D.")
            } else if let area, isMissing {
                VStack(spacing: 12) {
                    BBSEmptyState(
                        systemImage: "folder.badge.questionmark",
                        title: "Folder can no longer be found",
                        detail: "Callers see \(area) as empty until you choose its folder again.")
                    Button("Choose Folder Again…") { picker.begin(.relocate(area: area)) }
                        .buttonStyle(.borderedProminent)
                }
            } else if files.isEmpty {
                BBSEmptyState(
                    systemImage: "doc",
                    title: "This area has no files",
                    detail: "Add files with the + button, or drop them here. Files over "
                        + "\(BBSFileIndex.size(BBSFileLibrary.defaultMaxFileBytes)), "
                        + "hidden files and symlinks are skipped, and so are subfolders.")
            } else {
                List(files) { file in
                    row(file)
                }
                .listStyle(.plain)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let addMessage {
                HStack(alignment: .top, spacing: 8) {
                    Text(addMessage)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        self.addMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .overlay {
            if dropTargeted, area != nil, !isMissing {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        // Drag files in from Files or another app on iPad. Copied into the
        // area's folder; the originals stay where they were.
        .onDrop(of: BBSFileDrop.acceptedTypes, isTargeted: $dropTargeted) { providers in
            guard let area, !isMissing else { return false }
            BBSFileDrop.add(providers, to: area, library: library) { addMessage = $0 }
            return true
        }
        .toolbar {
            if let area, !isMissing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        picker.begin(.addFiles(area: area))
                    } label: {
                        Label("Add Files", systemImage: "plus")
                    }
                }
            }
        }
        .fileImporter(isPresented: Binding(get: { picker.isPresented },
                                           set: { if !$0 { picker.panelClosed() } }),
                      allowedContentTypes: picker.contentTypes,
                      allowsMultipleSelection: picker.allowsMultipleSelection) { result in
            let purpose = picker.finish()
            guard let purpose, case .success(let urls) = result else { return }
            if case .finished(let message) = BBSFilePick.apply(purpose, urls: urls, library: library) {
                addMessage = message
            }
        }
        .navigationTitle(area ?? "Files")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { file in
            NavigationStack { descriptionSheet(file) }
        }
    }

    private func row(_ file: BBSSharedFile) -> some View {
        let model = BBSFileRowModel.make(file, bytesPerSecond: bytesPerSecond)
        return HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.isText ? "doc.text" : "doc")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.about.isEmpty ? "No description" : model.about)
                        .font(.caption)
                        .foregroundStyle(model.about.isEmpty ? .tertiary : .secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.airtime)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(model.isLongTransfer ? Color.orange : Color.primary)
                    Text(model.size)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                // Indicator on, and the row is a tap gesture rather than a
                // Button, so the two tap targets do not fight: an explanation
                // with no indicator would eat the tap that opens the
                // description editor.
                .explain("How long this file takes on the air at the throughput this link "
                         + "is actually managing, and how big it is. Time is the figure "
                         + "that decides anything: a caller plans around it, and a "
                         + "flattering estimate is worse than none.")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            draftAbout = file.about
            editing = file
        }
    }

    private func descriptionSheet(_ file: BBSSharedFile) -> some View {
        Form {
            Section {
                TextField("Description", text: $draftAbout, axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                Text(file.name).font(.system(.callout, design: .monospaced))
            } footer: {
                // A filename alone tells a caller nothing, and on this link
                // they cannot afford to download one to find out what it is.
                Text("Callers see this beside the file. One line.")
            }
        }
        .navigationTitle("Description")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { editing = nil }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    library.setDescription(area: file.area, name: file.name,
                                           about: draftAbout)
                    editing = nil
                }
            }
        }
    }
}
#endif
