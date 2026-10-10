#if os(macOS)
import AppKit
import SwiftUI

/// One piece of a console row's header: a callsign, a chip, a badge.
struct ConsoleHeaderItem {
    enum Style: Equatable {
        /// Bare text, like the arrow between two callsigns.
        case plain
        /// A station. Clickable when the console links callsigns.
        case callsign
        /// A capsule, tinted, or filled for the one thing that asks for
        /// attention.
        case chip(prominent: Bool)
        /// A capsule led by a colored dot: the radio tag.
        case tag
        /// A small rounded rectangle: the duplicate count.
        case badge
        /// A symbol on its own: the old path icon.
        case icon
    }

    var style: Style
    var systemImage: String?
    var text: String
    var font: NSFont
    var color: NSColor
    var help: String?
    /// The station a click or right-click on this item is about.
    var callsign: String?

    static let chipPadding = NSSize(width: 5, height: 1)
    static let badgePadding = NSSize(width: 3, height: 1)
    static let iconGap: CGFloat = 3
    static let dotSize: CGFloat = 6

    /// The symbol's point size: two under the text, as the SwiftUI chips do.
    var symbolPointSize: CGFloat { max(font.pointSize - 1, 7) }

    /// How much room it takes.
    func size() -> NSSize {
        let textSize = text.isEmpty ? .zero : (text as NSString).size(withAttributes: [.font: font])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        switch style {
        case .plain, .callsign:
            return NSSize(width: ceil(textSize.width), height: lineHeight)
        case .icon:
            let side = ceil(symbolPointSize + 2)
            return NSSize(width: side, height: max(side, lineHeight))
        case .chip, .tag, .badge:
            let padding = style == .badge ? Self.badgePadding : Self.chipPadding
            var width = ceil(textSize.width)
            if style == .tag { width += Self.dotSize + Self.iconGap }
            if systemImage != nil { width += ceil(symbolPointSize + 1) + (text.isEmpty ? 0 : Self.iconGap) }
            return NSSize(width: width + padding.width * 2, height: lineHeight + padding.height * 2)
        }
    }
}

/// Everything a console row draws, built once per row and version.
struct ConsoleRowModel {
    var indicatorColor: NSColor
    var indicatorHelp: String
    var fill: NSColor?
    var outline: NSColor?
    var alpha: CGFloat
    var timestamp: String
    var timestampFont: NSFont
    var timestampAlpha: CGFloat
    var header: [ConsoleHeaderItem]
    var symbol: (name: String, help: String)?
    var symbolPointSize: CGFloat
    var message: NSAttributedString
    var messageHelp: String?
    /// A decoded APRS row puts its message under the callsigns when it would
    /// wrap. Every other row wraps it beside the header, as it always has.
    var wrapsBelow: Bool
    var isExpandable: Bool
    /// The duplicate paths, when the row is expanded.
    var expansion: [NSAttributedString]
    var accessibilityLabel: String
    /// The line as text, for Copy.
    var copyText: String

    static let messageFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let callsignFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    static let mineCallsignFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

    static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
    }

    static func color(_ color: Color) -> NSColor { NSColor(color) }

    /// The row for one group of lines.
    @MainActor
    static func make(group: ConsoleLineGroup,
                     timestampRun: ConsoleTimestampRuler.RunPosition,
                     beaconRepeat: BeaconRepeat?,
                     isExpanded: Bool,
                     environment env: ConsoleRowEnvironment,
                     fileNameIndex: FileNameIndex?,
                     decorated: Bool = true) -> ConsoleRowModel {
        let line = group.primary
        let facts = ConsoleLineFacts(line: line, environment: env,
                                     allViaPaths: group.allViaPaths, duplicateCount: group.duplicateCount)
        let mine = facts.mine
        let decoded = facts.isDecodedAPRS
        let fontSize = CGFloat(env.fontSize)
        let chipFont = roundedFont(size: fontSize - 1, weight: .medium)

        // Header
        var header: [ConsoleHeaderItem] = []
        func callsignItem(_ call: String, mineTint: Bool) -> ConsoleHeaderItem {
            let color: NSColor
            if mineTint {
                color = .systemPink
            } else if line.kind == .packet {
                color = NSColor(hue: ConsoleLineFacts.callsignHue(call), saturation: 0.35, brightness: 0.75, alpha: 1)
            } else {
                color = .secondaryLabelColor
            }
            return ConsoleHeaderItem(style: .callsign, text: call,
                                     font: mineTint ? mineCallsignFont : callsignFont, color: color,
                                     help: nil, callsign: env.linksCallsigns ? call : nil)
        }
        func chip(_ image: String?, _ text: String, _ tint: NSColor, help: String?, prominent: Bool = false) -> ConsoleHeaderItem {
            ConsoleHeaderItem(style: .chip(prominent: prominent), systemImage: image, text: text,
                              font: chipFont, color: tint, help: help)
        }
        let purple = color(.purple)

        if decoded {
            if let from = line.from {
                switch mine {
                case .fromYou, .yourFrameRepeated: header.append(callsignItem(from, mineTint: true))
                default: header.append(callsignItem(from, mineTint: false))
                }
            }
            switch mine {
            case .yourFrameRepeated(let digi):
                header.append(chip("checkmark.circle.fill", "\(digi) repeated you", .systemPink,
                                   help: "Your frame, heard back off \(digi)'s transmitter. "
                                       + "That digipeater heard you and passed it on.\n" + facts.pathLines))
            case .relayedByYou:
                header.append(chip("arrow.triangle.2.circlepath", "You relayed", .systemPink,
                                   help: "Your digipeater repeated this frame.\n" + facts.pathLines))
            default:
                if let path = facts.pathChipText {
                    header.append(chip(path.heardVia ? "arrow.triangle.2.circlepath" : nil, path.text,
                                       path.heardVia ? color(.indigo) : color(.green), help: path.help))
                }
            }
        } else {
            if let attribution = facts.repeatAttribution {
                header.append(ConsoleHeaderItem(
                    style: .plain, systemImage: "arrow.triangle.2.circlepath",
                    text: attribution.digis.joined(separator: ","),
                    font: .monospacedSystemFont(ofSize: fontSize, weight: .medium),
                    color: color(.indigo), help: facts.repeatHelp(attribution)))
            }
            if let from = line.from {
                header.append(callsignItem(from, mineTint: false))
                if let to = line.to {
                    header.append(ConsoleHeaderItem(style: .plain, text: "\u{2192}", font: messageFont,
                                                    color: .tertiaryLabelColor))
                    header.append(callsignItem(to, mineTint: false))
                }
            }
            if !group.allViaPaths.isEmpty || !line.via.isEmpty {
                header.append(ConsoleHeaderItem(style: .icon, systemImage: "arrow.triangle.branch", text: "",
                                                font: .systemFont(ofSize: 11), color: purple.withAlphaComponent(0.7),
                                                help: facts.digiPathTooltip))
            }
        }

        if group.duplicateCount > 0 {
            let tint = line.kind == .error ? color(ConsoleTheme.errorAccent) : purple
            header.append(ConsoleHeaderItem(
                style: .badge, text: "+\(group.duplicateCount)",
                font: .monospacedSystemFont(ofSize: 9, weight: .medium), color: tint,
                help: line.kind == .packet
                    ? "Received \(group.duplicateCount + 1) times via different paths (click to expand)"
                    : "Occurred \(group.duplicateCount + 1) times consecutively (click to expand)"))
        }
        if let id = line.radioID, let tag = env.radioTags[id] {
            let palette = ConsoleRadioTagView.palette
            header.append(ConsoleHeaderItem(style: .tag, text: tag.name, font: chipFont,
                                            color: color(palette[tag.colorIndex % palette.count]),
                                            help: "Heard on \(tag.name)"))
        }
        if decoded, mine == .toYou {
            header.append(chip("envelope.fill", "For you", .systemPink, help: "Addressed to you", prominent: true))
        }
        if decoded, let beaconRepeat, let from = line.from {
            header.append(ConsoleHeaderItem(
                style: .chip(prominent: false), systemImage: "repeat",
                text: "\u{00D7}\(beaconRepeat.ordinal)",
                font: roundedFont(size: fontSize - 1, weight: .semibold), color: .secondaryLabelColor,
                help: "\(from) has sent this same beacon \(beaconRepeat.ordinal) times in a row, "
                    + "starting at \(TimeDisplay.timeString(beaconRepeat.since)). Nothing in it has changed."))
        }

        // Message
        let text = facts.messageText
        let secondary = facts.messageIsSecondary(beaconRepeat: beaconRepeat)
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: messageFont,
            .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        // Links and highlights change no sizes, so a model built only to
        // measure a row leaves them out (`decorated: false`).
        if decorated {
            for range in facts.mentions(in: text) {
                attributed.addAttribute(.backgroundColor, value: NSColor.systemPink.withAlphaComponent(0.22),
                                        range: NSRange(range, in: text))
            }
            for target in facts.linkTargets(in: text, fileNameIndex: fileNameIndex) {
                let range = NSRange(target.range, in: text)
                attributed.addAttribute(.link, value: target.url, range: range)
            }
        }

        var symbol: (String, String)?
        if decoded, let s = line.aprs?.symbol {
            symbol = (APRSSymbolGlyph.systemImage(table: s.table, code: s.code),
                      APRSSymbolGlyph.label(table: s.table, code: s.code))
        }

        // The look of the row
        let indicator: NSColor
        switch facts.category {
        case .error: indicator = color(ConsoleTheme.errorAccent)
        case .system: indicator = NSColor.gray.withAlphaComponent(ConsoleTheme.systemIndicatorOpacity)
        case .id: indicator = .systemBlue
        case .beacon: indicator = .systemGreen
        case .mail: indicator = .systemOrange
        case .data: indicator = .systemPurple
        case .prompt: indicator = .systemCyan
        case .other: indicator = .systemBrown
        }
        let fill: NSColor?
        switch mine {
        case .toYou: fill = NSColor.systemPink.withAlphaComponent(0.14)
        case .fromYou, .yourFrameRepeated: fill = NSColor.systemPink.withAlphaComponent(0.07)
        case .relayedByYou, .mentionsYou: fill = NSColor.systemPink.withAlphaComponent(0.04)
        case .none:
            switch line.kind {
            case .system: fill = NSColor.gray.withAlphaComponent(ConsoleTheme.systemBackgroundOpacity)
            case .error: fill = NSColor.gray.withAlphaComponent(ConsoleTheme.errorBackgroundOpacity)
            case .packet: fill = nil
            }
        }

        // Duplicate paths, drawn under the row when it is open.
        var expansion: [NSAttributedString] = []
        if isExpanded, group.duplicateCount > 0 {
            let mono = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let monoMedium = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
            func entry(_ glyph: String, via: String?, note: String?, at time: String) -> NSAttributedString {
                let out = NSMutableAttributedString(string: glyph + " ", attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor])
                if let via {
                    out.append(NSAttributedString(string: "via ", attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]))
                    out.append(NSAttributedString(string: via + " ", attributes: [.font: monoMedium, .foregroundColor: purple]))
                } else if let note {
                    out.append(NSAttributedString(string: note + " ", attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]))
                }
                out.append(NSAttributedString(string: "at \(time)", attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]))
                return out
            }
            if !line.via.isEmpty {
                expansion.append(entry("\u{251C}", via: line.viaDisplay, note: nil, at: line.timestampString))
            }
            for (index, dup) in group.duplicates.enumerated() {
                let isLast = index == group.duplicates.count - 1 && line.via.isEmpty
                expansion.append(entry(isLast ? "\u{2514}" : "\u{251C}",
                                       via: dup.via.isEmpty ? nil : dup.viaDisplay,
                                       note: dup.via.isEmpty && line.kind == .packet ? "(no digi path recorded)" : nil,
                                       at: dup.timestampString))
            }
        }

        var spoken = [line.timestampString]
        spoken.append(contentsOf: header.map { $0.text }.filter { !$0.isEmpty })
        spoken.append(text)
        var copy = line.timestampString
        if let from = line.from { copy += " " + from + (facts.isDecodedAPRS ? "" : line.to.map { ">" + $0 } ?? "") + ":" }
        copy += " " + text

        return ConsoleRowModel(
            indicatorColor: indicator,
            indicatorHelp: facts.categoryTooltip,
            fill: fill,
            outline: decoded && mine == .toYou ? NSColor.systemPink.withAlphaComponent(0.5) : nil,
            alpha: facts.isDigipeatEcho && !decoded ? 0.6 : 1,
            timestamp: line.timestampString,
            timestampFont: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
            timestampAlpha: timestampRun.printsTimestamp ? 1 : CGFloat(ConsoleTheme.repeatedTimestampOpacity),
            header: header,
            symbol: symbol.map { (name: $0.0, help: $0.1) },
            symbolPointSize: fontSize,
            message: attributed,
            messageHelp: decoded && decorated ? facts.rawHelp : nil,
            wrapsBelow: decoded,
            isExpandable: group.duplicateCount > 0,
            expansion: expansion,
            accessibilityLabel: spoken.joined(separator: ", "),
            copyText: copy)
    }
}
#endif
