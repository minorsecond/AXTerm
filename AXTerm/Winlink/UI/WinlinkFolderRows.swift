import SwiftUI

/// The mail folders as a section of the main sidebar, rather than a column
/// of their own.
///
/// Selection is drawn by hand instead of through `List(selection:)`. The
/// sidebar's list already binds its selection to `NavigationItem`, and one
/// list carries one selection type — the same reason the "All Packets" row
/// beside it is hand-drawn.
struct WinlinkFolderRows: View {

    @ObservedObject var viewModel: WinlinkMailboxViewModel

    @State private var newFolderName = ""
    @State private var showingNewFolder = false
    @State private var renamingFolder: WinlinkFolderRecord?
    @State private var renameText = ""
    @State private var confirmingEmptyTrash = false
    /// Counted when the menu item is chosen, so the confirmation can name a
    /// number instead of asking about an unknown quantity.
    @State private var trashCount = 0

    var body: some View {
        Section("Folders") {
            ForEach(viewModel.folders, id: \.id) { folder in
                row(for: folder)
            }
            newFolderRow
        }
    }

    private func row(for folder: WinlinkFolderRecord) -> some View {
        let isSelected = viewModel.selectedFolderID == folder.id
        return HStack(spacing: 6) {
            Label(folder.name, systemImage: icon(for: folder))
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.selectedFolderID = folder.id }
        .contextMenu {
            if folder.systemRole == nil {
                Button("Rename\u{2026}") {
                    renamingFolder = folder
                    renameText = folder.name
                }
                Button("Delete Folder", role: .destructive) {
                    if let id = folder.id { viewModel.deleteFolder(id: id) }
                }
            }
            if folder.role == .trash {
                // The only way the mailbox ever gets smaller. Until this
                // existed the Trash was a folder mail went into and never
                // left.
                Button("Empty Trash\u{2026}", role: .destructive) {
                    trashCount = viewModel.trashedMessageCount()
                    confirmingEmptyTrash = trashCount > 0
                }
                .disabled(viewModel.trashedMessageCount() == 0)
            }
        }
    }

    /// Carries the dialogs as well as the button. They have to hang off a
    /// row: a modifier applied to the `Section` itself would erase its type,
    /// and the list would stop reading it as a section.
    private var newFolderRow: some View {
        Button {
            showingNewFolder = true
        } label: {
            Label("New Folder\u{2026}", systemImage: "folder.badge.plus")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .help("Create a mail folder. Messages moved into it survive app restarts.")
        .confirmationDialog(
            trashCount == 1
                ? "Delete the message in the Trash permanently?"
                : "Delete \(trashCount) messages in the Trash permanently?",
            isPresented: $confirmingEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) { viewModel.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone, here or on your other devices.")
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
