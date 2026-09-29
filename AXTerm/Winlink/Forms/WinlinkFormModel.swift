import Foundation

/// A fillable Winlink form: the official template text (verbatim from the
/// Winlink Standard Templates pack) plus native field descriptors that
/// drive the SwiftUI editor.
nonisolated struct WinlinkFormTemplate: Identifiable, Sendable {

    var id: String
    var title: String
    var category: String
    /// SF Symbol for the picker.
    var icon: String
    var summary: String
    /// The Standard Templates `.txt` content, verbatim.
    var templateText: String
    /// The viewer HTML filename (drives the XML attachment name and the
    /// `display_form` parameter). Empty = plain-text form, no XML.
    var displayFormFile: String
    var replyTemplateFile: String = ""
    var fields: [WinlinkFormField]

    /// `RMS_Express_Form_<viewer base>.xml`, per Winlink Express.
    var xmlAttachmentName: String? {
        guard !displayFormFile.isEmpty else { return nil }
        let base = (displayFormFile as NSString).deletingPathExtension
        return "RMS_Express_Form_\(base).xml"
    }
}

/// One form input, keyed by the template's `<var name>`.
nonisolated struct WinlinkFormField: Identifiable, Sendable {

    enum Kind: Sendable {
        case text
        case multiline
        /// Fixed options (segmented/menu picker).
        case choice([String])
        /// YES / NO / UNK — the utility-status rows of the FSR.
        case yesNoUnknown
    }

    /// Where a default value comes from before the user edits.
    enum AutoFill: Sendable {
        case callsign
        case dateTimeLocal      // 2026-08-23 07:30:00
        case utcDTG             // 231430Z AUG 2026
        case latitude           // signed decimal
        case longitude
        case gridSquare
        case locationSource     // "GPS" / "Grid square"
        case operatorName
        case operatorNameWithTitle
        case operatorPhone
        case operatorEmail
        case organization
        case city
        case state
        case county
        case fixed(String)
        /// Computed from the full context (composite defaults).
        case custom(@Sendable (WinlinkFormContext) -> String)
    }

    var id: String              // the <var> name, template casing
    var label: String
    var kind: Kind = .text
    var autoFill: AutoFill?
    var placeholder: String = ""
    var help: String = ""
    var required: Bool = false
    /// Hidden fields are auto-filled and never shown in the editor
    /// (coordinates, template version, map bookkeeping).
    var hidden: Bool = false
    /// Section header in the editor; fields with the same section group.
    var section: String = ""
}
