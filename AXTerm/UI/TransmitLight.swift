import SwiftUI

/// The TX light: a radio's status dot turns red, with a soft glow, while it
/// transmits (`PacketEngine.transmittingRadios`). On the Mac toolbar and
/// the iPhone and iPad status line (operator, 2026-10-07).
enum TransmitLight {
    static let color = Color.red

    static func dotColor(base: Color, transmitting: Bool) -> Color {
        transmitting ? color : base
    }

    /// The word beside the dot. The iOS strip uses red for a failed link
    /// too, so a transmitting radio says so; a link that needs attention
    /// keeps its own words.
    static func label(transmitting: Bool, needsAttention: Bool) -> String? {
        transmitting && !needsAttention ? "TX" : nil
    }
}

extension View {
    /// The glow around a dot that is transmitting.
    func transmitGlow(_ on: Bool) -> some View {
        shadow(color: on ? TransmitLight.color.opacity(0.7) : .clear, radius: on ? 3 : 0)
            .animation(.easeOut(duration: 0.2), value: on)
    }
}
