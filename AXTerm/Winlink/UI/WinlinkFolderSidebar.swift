import SwiftUI

/// Folder list: system folders first, then user folders, with
/// create/rename/delete for user folders.
struct WinlinkFolderSidebar: View {

    @ObservedObject var viewModel: WinlinkMailboxViewModel

    @State private var newFolderName = ""
    @State private var showingNewFolder = false
    @State private var renamingFolder: WinlinkFolderRecord?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { viewModel.selectedFolderID },
                set: { viewModel.selectedFolderID = $0 })) {
                Section("Folders") {
                    ForEach(viewModel.folders, id: \.id) { folder in
                        Label(folder.name, systemImage: icon(for: folder))
                            .tag(folder.id)
                            .contextMenu {
                                if folder.systemRole == nil {
                                    Button("Rename…") {
                                        renamingFolder = folder
                                        renameText = folder.name
                                    }
                                    Button("Delete Folder", role: .destructive) {
                                        if let id = folder.id { viewModel.deleteFolder(id: id) }
                                    }
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Button {
                    showingNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Create a mail folder. Messages moved into it survive app restarts.")
                Spacer()
            }
            .padding(6)
        }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                viewModel.createFolder(named: newFolderName)
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename Folder", isPresented: Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let id = renamingFolder?.id {
                    viewModel.renameFolder(id: id, to: renameText)
                }
                renamingFolder = nil
            }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
    }

    private func icon(for folder: WinlinkFolderRecord) -> String {
        switch folder.role {
        case .inbox: return "tray.and.arrow.down"
        case .outbox: return "tray.and.arrow.up"
        case .sent: return "paperplane"
        case .drafts: return "doc.badge.ellipsis"
        case .archive: return "archivebox"
        case .trash: return "trash"
        case nil: return "folder"
        }
    }
}
