import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
import AudioToolbox
#endif

/// The seam between AXTerm and whichever OS it is running on.
///
/// AXTerm began as a Mac app and most of it is already portable: the AX.25
/// decoder, the routing inference, the Winlink protocol stack and the store
/// are all plain Swift with no idea what a window is. What is *not* portable
/// is the handful of places that reach for AppKit to copy a string, pick a
/// file, or name a colour.
///
/// Rather than scatter `#if os(macOS)` through those call sites, the
/// platform differences are named once here. Call sites then read the same on
/// both platforms, and the list of things that genuinely differ stays short
/// enough to see in one file.
///
/// Deliberately thin. This is a translation layer, not a UI framework: where
/// the two platforms disagree about behaviour rather than spelling — a Mac
/// has windows and a phone does not — the difference belongs in the view,
/// not hidden behind a shim that pretends it is absent.

// MARK: - Type names

#if os(macOS)
typealias PlatformColor = NSColor
typealias PlatformView = NSView
typealias PlatformLabel = NSTextField
typealias PlatformFont = NSFont
typealias PlatformImage = NSImage
#else
typealias PlatformColor = UIColor
typealias PlatformView = UIView
typealias PlatformLabel = UILabel
typealias PlatformFont = UIFont
typealias PlatformImage = UIImage
#endif

extension Color {
    /// Builds a SwiftUI colour from whichever native colour this platform
    /// uses, so call sites do not name either one.
    init(platform color: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}

extension Image {
    init(platform image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

extension PlatformColor {
    /// The system accent colour under its two different names.
    static var platformAccent: PlatformColor {
        #if os(macOS)
        return .controlAccentColor
        #else
        return .tintColor
        #endif
    }

    /// `withAlphaComponent` exists on both, but only NSColor guarantees the
    /// result in the same colour space; naming it here keeps the intent
    /// visible where analytics styling mixes alpha into an accent.
    func platformAlpha(_ alpha: CGFloat) -> PlatformColor {
        withAlphaComponent(alpha)
    }
}


/// Semantic colours, which the two platforms spell differently.
///
/// These are the system's own answers to "what colour is a separator here",
/// so they follow appearance, accessibility contrast settings and dark mode
/// on both platforms. Hard-coding a grey instead would look right in exactly
/// one configuration.
extension PlatformColor {

    /// Background for a card or panel that sits above the window background.
    static var platformCardBackground: PlatformColor {
        #if os(macOS)
        return .controlBackgroundColor
        #else
        return .secondarySystemBackground
        #endif
    }

    static var platformSeparator: PlatformColor {
        #if os(macOS)
        return .separatorColor
        #else
        return .separator
        #endif
    }

    static var platformLabel: PlatformColor {
        #if os(macOS)
        return .labelColor
        #else
        return .label
        #endif
    }

    static var platformSecondaryLabel: PlatformColor {
        #if os(macOS)
        return .secondaryLabelColor
        #else
        return .secondaryLabel
        #endif
    }

    static var platformTertiaryLabel: PlatformColor {
        #if os(macOS)
        return .tertiaryLabelColor
        #else
        return .tertiaryLabel
        #endif
    }

    static var platformQuaternaryLabel: PlatformColor {
        #if os(macOS)
        return .quaternaryLabelColor
        #else
        return .quaternaryLabel
        #endif
    }

    /// Background behind editable or scrolling text.
    static var platformTextBackground: PlatformColor {
        #if os(macOS)
        return .textBackgroundColor
        #else
        return .systemBackground
        #endif
    }

    /// Fill behind a selected row or control.
    static var platformSelectedControl: PlatformColor {
        #if os(macOS)
        return .selectedControlColor
        #else
        return .tintColor.withAlphaComponent(0.25)
        #endif
    }
}


extension PlatformImage {
    /// PNG bytes for an image the app captured itself.
    ///
    /// The two platforms take different routes — AppKit goes through a TIFF
    /// representation and a bitmap rep, UIKit encodes directly — and both
    /// can fail, so the result is optional rather than force-unwrapped. An
    /// offline basemap that silently stored nothing would look exactly like
    /// one that stored a blank tile, and the operator only finds out when
    /// they are somewhere with no signal.
    func platformPNGData() -> Data? {
        #if os(macOS)
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #else
        return pngData()
        #endif
    }
}

// MARK: - Pasteboard

/// Copying text to the system clipboard.
nonisolated enum PlatformPasteboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

// MARK: - Screen metrics

@MainActor
enum PlatformScreen {
    /// Points-to-pixels for the current display, for Metal drawable sizing.
    ///
    /// Falls back to 2.0 rather than 1.0 when no display can be identified:
    /// every device this app runs on has a Retina display, and guessing low
    /// renders a blurry graph while guessing high only costs memory.
    static var scale: CGFloat {
        #if os(macOS)
        return NSScreen.main?.backingScaleFactor ?? 2.0
        #else
        return UIScreen.main.scale
        #endif
    }
}

// MARK: - Idioms

/// What kind of machine this is, where that genuinely changes behaviour.
///
/// Used sparingly. Most layout differences are better expressed as size
/// classes, which adapt to a Mac window being dragged narrow as well as to a
/// phone — this is for the cases where the *capability* differs, not the
/// space: whether there is a serial port, whether windows exist, whether a
/// pointer is available for hover.
nonisolated enum PlatformIdiom {

    /// True where the app can open additional windows.
    static var supportsMultipleWindows: Bool {
        #if os(macOS)
        return true
        #else
        // iPadOS supports scenes, but a phone does not, and the mail UI
        // opens messages in place on both rather than maintaining two
        // presentation paths.
        return false
        #endif
    }

    /// True where a wired TNC can be reached over a serial port.
    ///
    /// iOS has no IOKit and no user-accessible USB serial, so a handheld
    /// reaches a TNC over the network (Direwolf or LinBPQ on the LAN) or
    /// over Bluetooth. Code that offers a serial option must ask first
    /// rather than presenting a control that cannot work.
    static var supportsSerialPorts: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// True where hovering a pointer is a meaningful interaction.
    ///
    /// Tooltips are load-bearing in this app — CLAUDE.md §11 requires every
    /// advanced metric to explain its derivation — so a platform with no
    /// hover needs those explanations reachable another way, not dropped.
    static var supportsHover: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Control idioms

extension PlatformColor {
    /// The window's own background, behind everything else.
    static var platformWindowBackground: PlatformColor {
        #if os(macOS)
        return .windowBackgroundColor
        #else
        return .systemBackground
        #endif
    }
}

extension View {
    /// A checkbox on macOS, a switch on iOS.
    ///
    /// The same choice, expressed the way each platform expresses one. A
    /// checkbox on a touch screen is a tap target three times too small,
    /// and a switch in a Mac settings pane looks like a control from
    /// somebody else's app.
    @ViewBuilder
    func platformCheckboxToggle() -> some View {
        #if os(macOS)
        self.toggleStyle(.checkbox)
        #else
        self.toggleStyle(.switch)
        #endif
    }

    /// An inset table with alternating row backgrounds where the platform
    /// has them.
    ///
    /// Row striping is a macOS table convention that iOS does not share;
    /// asking for it there is not merely unavailable, it would look wrong.
    @ViewBuilder
    func platformInsetTable() -> some View {
        #if os(macOS)
        self.tableStyle(.inset(alternatesRowBackgrounds: true))
        #else
        self.tableStyle(.inset)
        #endif
    }
}

// MARK: - Alert sounds

/// Short attention sounds for link events.
///
/// A station being called while the operator is looking elsewhere is exactly
/// the moment a sound earns its place, so this stays audible on both
/// platforms rather than being dropped in the port. macOS has named system
/// sounds; iOS plays the corresponding system alert IDs.
nonisolated enum PlatformSound {

    /// Somebody connected to us.
    static func playInboundConnection() {
        #if os(macOS)
        NSSound(named: "Glass")?.play()
        #else
        AudioServicesPlaySystemSound(1013)
        #endif
    }

    /// Our own outbound connection came up.
    static func playOutboundConnection() {
        #if os(macOS)
        NSSound(named: "Ping")?.play()
        #else
        AudioServicesPlaySystemSound(1057)
        #endif
    }
}

extension View {
    /// A text-only button that reads as a link.
    ///
    /// `.buttonStyle(.link)` is macOS-only. On iOS the same affordance is a
    /// plain button tinted with the accent colour — the platform's own way of
    /// saying "this text is tappable".
    @ViewBuilder
    func platformLinkButton() -> some View {
        #if os(macOS)
        self.buttonStyle(.link)
        #else
        self.buttonStyle(.plain).foregroundStyle(Color.accentColor)
        #endif
    }
}

extension PlatformColor {
    /// sRGB components, for handing a colour to Metal or a shader.
    ///
    /// Both platforms can refuse to convert — a pattern or catalog colour has
    /// no single set of components — so this falls back to a mid grey rather
    /// than trapping. A graph drawn in grey is a cosmetic problem; a crash
    /// while rendering it is not.
    var sRGBComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        #if os(macOS)
        guard let converted = usingColorSpace(.sRGB) else { return (0.5, 0.5, 0.5, 1) }
        return (converted.redComponent, converted.greenComponent,
                converted.blueComponent, converted.alphaComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return (0.5, 0.5, 0.5, 1) }
        return (r, g, b, a)
        #endif
    }
}

extension View {
    /// A vertical list of mutually exclusive choices.
    ///
    /// macOS has radio buttons; iOS does not, and the nearest honest
    /// equivalent for a short list is the inline picker, which shows every
    /// option with a checkmark on the chosen one. A wheel or menu would hide
    /// the alternatives, and seeing them is the point of a radio group.
    @ViewBuilder
    func platformRadioGroup() -> some View {
        #if os(macOS)
        self.pickerStyle(.radioGroup)
        #else
        self.pickerStyle(.inline)
        #endif
    }

    /// Escape-to-dismiss, where there is an Escape key.
    ///
    /// A sheet on iOS is dismissed by dragging it down or by its own Cancel
    /// button, so there is nothing to bind and nothing lost.
    @ViewBuilder
    func platformEscape(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        self.onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

extension PlatformColor {
    /// The fill for every other row in a striped list.
    ///
    /// macOS has a system answer (`alternatingContentBackgroundColors`); iOS
    /// does not stripe lists at all, so a faint tint of the label colour
    /// stands in — visible enough to group a row, quiet enough not to look
    /// like a Mac list on a phone.
    static var platformAlternatingRow: PlatformColor {
        #if os(macOS)
        return NSColor.alternatingContentBackgroundColors.count > 1
            ? NSColor.alternatingContentBackgroundColors[1]
            : .platformCardBackground
        #else
        return UIColor.label.withAlphaComponent(0.04)
        #endif
    }

    /// Highlight behind a search match.
    static var platformSearchHighlight: PlatformColor {
        #if os(macOS)
        return NSColor.systemYellow.withAlphaComponent(0.35)
        #else
        return UIColor.systemYellow.withAlphaComponent(0.35)
        #endif
    }
}
