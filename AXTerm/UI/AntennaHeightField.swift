import SwiftUI

/// Antenna height above ground, entered in whichever unit the operator thinks
/// in and stored in metres.
///
/// A separate view because height is asked for in three places — the
/// operator's own station in settings, the assumption used for everyone else,
/// and a recorded height on an identity page — and a field that rounds
/// differently in one of them would produce forecasts that disagree.
///
/// Feet by default: a US operator knows their mast in feet, and converting in
/// their head is exactly how a 40 ft tower gets entered as 40 m.
struct AntennaHeightField: View {

    let title: String
    /// Metres above ground. Zero is a real answer — a handheld at street
    /// level — so there is no "unset" state here; the caller decides what
    /// absence means.
    @Binding var metres: Double
    @Binding var isFeet: Bool
    var prompt: String = "Height"

    private static let metresPerFoot = 0.3048

    /// Rounded to whole units, because nobody knows their antenna height to
    /// the centimetre and a field showing 12.192 m invites the belief that
    /// they do.
    private var displayed: Double {
        get { (isFeet ? metres / Self.metresPerFoot : metres).rounded() }
        nonmutating set { metres = isFeet ? newValue * Self.metresPerFoot : newValue }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            TextField(prompt, value: Binding(get: { displayed },
                                             set: { displayed = max(0, $0) }),
                      format: .number.precision(.fractionLength(0)))
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Picker("", selection: $isFeet) {
                Text("ft").tag(true)
                Text("m").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76)
        }
    }
}
