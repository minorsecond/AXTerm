import SwiftUI

/// A small capsule on a console row: how a frame got here, which radio heard
/// it, whether it is for you.
struct ConsoleChip: View {
    var systemImage: String?
    let text: String
    let tint: Color
    var fontSize: Double = 11
    /// Filled rather than tinted, for the one thing on a row that asks for
    /// attention: a message addressed to you.
    var prominent = false

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: fontSize - 2, weight: .semibold))
            }
            Text(text)
                .font(.system(size: fontSize - 1, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(prominent ? tint.opacity(0.9) : tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// Which radio heard a line, when the console holds lines from more than one.
struct ConsoleRadioTagView: View {
    let tag: ConsoleRadioTags.Tag
    var fontSize: Double = 11

    /// Kept clear of pink, which marks your own traffic, and of green and
    /// indigo, which the path chip uses.
    static let palette: [Color] = [.teal, .orange, .cyan, .yellow, .mint, .brown]

    private var color: Color { Self.palette[tag.colorIndex % Self.palette.count] }

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(tag.name)
                .font(.system(size: fontSize - 1, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(color.opacity(0.13), in: Capsule())
        .fixedSize()
        .help("Heard on \(tag.name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heard on \(tag.name)")
    }
}

/// Marks a beacon that repeats the same station's last one word for word.
struct BeaconRepeatChip: View {
    let beaconRepeat: BeaconRepeat
    let station: String
    var fontSize: Double = 11

    private var help: String {
        "\(station) has sent this same beacon \(beaconRepeat.ordinal) times in a row, "
            + "starting at \(TimeDisplay.timeString(beaconRepeat.since)). Nothing in it has changed."
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "repeat")
                .font(.system(size: fontSize - 3, weight: .bold))
            Text("\u{00D7}\(beaconRepeat.ordinal)")
                .font(.system(size: fontSize - 1, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .fixedSize()
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Repeat beacon, \(beaconRepeat.ordinal) in a row")
    }
}

/// The new-lines pill that replaces the jump-to-bottom arrow while the reader
/// is scrolled up.
///
/// With nothing new it is the plain arrow. Once lines arrive it opens into a
/// capsule that counts them, and a message for you turns part of it pink, so
/// a reader deep in the history knows whether coming back is worth it.
struct ConsoleNewLinesPill: View {
    let count: ConsoleUnseen.Count
    let action: () -> Void

    private var label: String {
        count.total == 1 ? "1 new line" : "\(count.total.formatted()) new lines"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .symbolEffect(.bounce, value: count.total)
                if count.total > 0 {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(count.total)))
                    if count.forYou > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "envelope.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text("\(count.forYou) for you")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(count.forYou)))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.pink, in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .foregroundStyle(count.total > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.leading, count.total > 0 ? 12 : 10)
            .padding(.trailing, count.forYou > 0 ? 5 : (count.total > 0 ? 12 : 10))
            .frame(minWidth: 34, minHeight: 32)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: count)
        .help(count.total > 0 ? "Jump to the newest line" : "Jump to the bottom")
        .accessibilityLabel(count.total > 0
            ? "\(label)\(count.forYou > 0 ? ", \(count.forYou) for you" : ""). Jump to the newest."
            : "Jump to the bottom")
    }
}
