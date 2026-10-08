import SwiftUI

/// The busiest Settings pages show what an operator needs day to day and
/// fold the rest under Advanced (park rehearsal 2026-10-08: "some of the
/// settings pages have too much"). Nothing is removed, the page remembers
/// whether Advanced was left open, and a link into a folded section still
/// lands there.
nonisolated enum SettingsFold {
    static func showsAdvanced(stored: Bool, landing: SettingsSection?, folded: Set<SettingsSection>) -> Bool {
        stored || landing.map(folded.contains) == true
    }
}

/// The row that opens and closes a page's Advanced sections.
struct SettingsAdvancedToggle: View {
    @Binding var isShown: Bool
    /// What is folded, said while it is closed.
    let summary: String

    var body: some View {
        Section {
            Button {
                withAnimation { isShown.toggle() }
            } label: {
                HStack {
                    Text("Advanced")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isShown ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isShown ? "Shown" : "Hidden")
        } footer: {
            if !isShown {
                Text(summary)
            }
        }
    }
}

extension View {
    /// Opens Advanced for a link into one of its sections, and keeps it open.
    func opensAdvanced(_ isShown: Binding<Bool>, for folded: Set<SettingsSection>,
                       router: SettingsRouter) -> some View {
        onAppear {
            if let section = router.highlightSection, folded.contains(section) { isShown.wrappedValue = true }
        }
        .onChange(of: router.highlightSection) { _, section in
            if let section, folded.contains(section) { isShown.wrappedValue = true }
        }
    }
}
