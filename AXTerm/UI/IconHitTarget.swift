import SwiftUI

/// Grows a glyph's tappable area without growing the glyph.
///
/// SF Symbols in a toolbar are around 17pt square. That is a comfortable
/// pointer target and an uncomfortable finger one — the HIG asks for 44pt,
/// and a row of bare icons at that size is the difference between a control
/// an operator uses and one they avoid. Wearing gloves in the field, it is
/// the difference between usable and not.
///
/// The frame is invisible: `contentShape` is what makes the padding actually
/// receive the tap, and without it the extra area is decorative.
struct IconHitTarget: ViewModifier {
    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(minWidth: size, minHeight: size)
            .contentShape(Rectangle())
    }
}

extension View {
    /// Applies a finger-sized hit target around a glyph.
    func iconHitTarget(_ size: CGFloat) -> some View {
        modifier(IconHitTarget(size: size))
    }
}
