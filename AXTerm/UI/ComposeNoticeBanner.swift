import SwiftUI

/// A notice across the compose bar with one action, such as "IC-705 is on
/// the APRS channel" with Switch to Packet.
///
/// The text wraps to at most three lines. It used to grow without limit,
/// and SwiftUI sizes a window's minimum at the narrowest width, where that
/// one line wrapped a word at a time and needed more height than the
/// screen: a connected APRS radio pushed the main window past the bottom
/// of the display (2026-10-10).
struct ComposeNoticeBanner: View {
    let text: String
    let systemImage: String
    let tint: Color
    let actionTitle: String
    let actionHelp: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1...3)
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help(actionHelp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }
}
