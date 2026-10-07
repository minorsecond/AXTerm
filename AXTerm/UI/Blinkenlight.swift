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

/// A link's status dot that also shows its traffic, in place of two activity
/// lights beside it: three dots in a row read as a loading indicator. The dot
/// turns red while a frame goes out, and a ring pulses outward from it when
/// one comes in.
struct ActivityStatusDot: View {
    let color: Color
    let rxTrigger: Date
    let txTrigger: Date
    @State private var transmitting = false
    @State private var ringScale: CGFloat = 1
    @State private var ringOpacity: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.green, lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)
            Circle()
                .fill(transmitting ? Color.red : color)
                .frame(width: 8, height: 8)
                .animation(transmitting ? .easeIn(duration: 0.05) : .easeOut(duration: 0.4), value: transmitting)
        }
        .frame(width: 10, height: 10)
        .onChange(of: rxTrigger) { _, _ in
            ringScale = 1
            ringOpacity = 0.9
            withAnimation(.easeOut(duration: 0.6)) {
                ringScale = 2.2
                ringOpacity = 0
            }
        }
        .onChange(of: txTrigger) { _, _ in
            transmitting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { transmitting = false }
        }
    }
}
