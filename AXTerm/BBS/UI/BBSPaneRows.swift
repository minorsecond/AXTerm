import SwiftUI

/// The mailbox's four panes, as a section of the main sidebar.
///
/// Selection is drawn by hand rather than through `List(selection:)`: the
/// sidebar's list already binds its selection to `NavigationItem`, and one
/// list carries one selection type.
struct BBSPaneRows: View {

    @Binding var pane: BBSPane
    /// Callers currently connected, for the badge. Zero draws nothing.
    let liveCallers: Int
    let messageCount: Int

    var body: some View {
        Section("Mailbox") {
            ForEach(BBSPane.allCases) { item in
                row(item)
            }
        }
    }

    private func row(_ item: BBSPane) -> some View {
        let isSelected = pane == item
        return HStack(spacing: 6) {
            Label(item.rawValue, systemImage: item.systemImage)
            Spacer()
            if let badge = badge(for: item) {
                Text("\(badge)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture { pane = item }
    }

    /// Only counts that change on their own are worth a badge. Directory and
    /// Files are what the operator put there, and a number beside them would
    /// be decoration.
    private func badge(for item: BBSPane) -> Int? {
        switch item {
        case .messages: return messageCount > 0 ? messageCount : nil
        case .callers: return liveCallers > 0 ? liveCallers : nil
        case .directory, .files: return nil
        }
    }
}
