import SwiftUI

/// A tiny activity lamp: lights on every change of `trigger` and fades out.
///
/// The toolbar capsule shows a pair for RX and TX. With several radios the
/// sidebar shows a pair per radio, so this lives here rather than as a
/// private struct of the main window.
struct Blinkenlight: View {
    let color: Color
    let trigger: Date
    @State private var isActive = false

    var body: some View {
        Circle()
            .fill(isActive ? color : Color.gray.opacity(0.2))
            .frame(width: 5, height: 5)
            .animation(isActive ? .easeIn(duration: 0.05) : .easeOut(duration: 0.4), value: isActive)
            .onChange(of: trigger) { _, _ in
                isActive = true
                // Turn off after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    isActive = false
                }
            }
    }
}
