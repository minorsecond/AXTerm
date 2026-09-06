//
//  IntervalPicker.swift
//  AXTerm
//
//  Setting a length of time, without lying about precision.
//
//  Paced-transmission settings are all the same shape: a floor or a
//  ceiling, in seconds or minutes, whose sensible values span three orders
//  of magnitude. Steppers made that click-torture. A fixed preset menu
//  fixed the clicking and introduced a different problem — the operator
//  can only have the intervals someone else thought of, and a value dialed
//  in before the presets existed renders as a stranger in the list.
//
//  So: presets for the common case, one click; a custom editor for
//  everything else, in whatever unit the number is naturally spoken in.
//  Ninety minutes is "1 hr 30 min" in the menu and "90 minutes" in the
//  editor, because those are the same interval and both are how someone
//  would say it.
//
//  The formatting and unit choice live in `IntervalFormat`, apart from the
//  view, because they are the part with rules worth testing.
//

import SwiftUI

/// A unit an interval is spoken in. Ordered smallest first.
nonisolated enum IntervalUnit: String, CaseIterable, Identifiable, Sendable {
    case seconds, minutes, hours, days

    var id: String { rawValue }

    /// How many seconds one of these is.
    var seconds: Int {
        switch self {
        case .seconds: 1
        case .minutes: 60
        case .hours: 3600
        case .days: 86_400
        }
    }

    /// Plural name for the unit menu.
    var name: String { rawValue }

    /// Singular or plural, as the count needs.
    func name(for amount: Int) -> String {
        amount == 1 ? String(name.dropLast()) : name
    }

    /// The compact form used in a menu, where the row is already narrow.
    var abbreviation: String {
        switch self {
        case .seconds: "s"
        case .minutes: "min"
        case .hours: "hr"
        case .days: "d"
        }
    }
}

/// Turning an interval into words, and back into a unit to edit it in.
nonisolated enum IntervalFormat {

    /// Longest interval any of these settings may be given. A month of
    /// silence is indistinguishable from the feature being switched off,
    /// and switching it off is what the Off entry is for.
    static let maximumSeconds = 30 * 86_400

    /// The interval in words: `"Off"`, `"90 s"`, `"5 min"`, `"1 hour"`,
    /// `"1 hr 30 min"`, `"2 days"`.
    ///
    /// Two components at most. "1 hr 30 min 20 s" is a stopwatch reading,
    /// not a setting anyone chose, and the third component is always the
    /// one carrying no meaning.
    static func label(seconds: Int, off: String = "Off") -> String {
        guard seconds > 0 else { return off }
        let parts = components(seconds: seconds).prefix(2)
        return parts.map { part in
            // The largest single-unit values read better spelled out —
            // "1 hour" rather than "1 hr" — but only when they stand alone.
            if parts.count == 1 && (part.unit == .hours || part.unit == .days) {
                return "\(part.amount) \(part.unit.name(for: part.amount))"
            }
            return "\(part.amount) \(part.unit.abbreviation)"
        }.joined(separator: " ")
    }

    /// The interval split into whole units, largest first, zeroes omitted.
    static func components(seconds: Int) -> [(amount: Int, unit: IntervalUnit)] {
        var remaining = max(0, seconds)
        var result: [(Int, IntervalUnit)] = []
        for unit in IntervalUnit.allCases.reversed() {
            let amount = remaining / unit.seconds
            if amount > 0 {
                result.append((amount, unit))
                remaining -= amount * unit.seconds
            }
        }
        return result.map { (amount: $0.0, unit: $0.1) }
    }

    /// The unit this interval should be *edited* in: the largest one that
    /// divides it exactly, so 90 minutes opens as "90 minutes" rather than
    /// as an hour with a remainder the editor cannot hold.
    ///
    /// Never smaller than `floor`, which is the granularity the setting is
    /// stored at — offering seconds for a value kept in minutes would let
    /// the operator type a number the store silently rounds away.
    static func naturalUnit(seconds: Int, notBelow floor: IntervalUnit = .seconds) -> IntervalUnit {
        let usable = IntervalUnit.allCases.filter { $0.seconds >= floor.seconds }
        guard seconds > 0 else { return usable.first ?? floor }
        return usable.reversed().first { seconds % $0.seconds == 0 } ?? floor
    }

    /// Units offered in the custom editor for a setting stored at `floor`.
    static func units(notBelow floor: IntervalUnit) -> [IntervalUnit] {
        IntervalUnit.allCases.filter { $0.seconds >= floor.seconds }
    }

    /// Presets with the current value spliced in when it is not one of
    /// them. A macOS pop-up whose selection matches no tag renders blank,
    /// so a value set before these presets existed — or typed into the
    /// custom editor — has to be in the list to be shown at all.
    static func options(presets: [Int], current: Int) -> [Int] {
        guard current > 0, !presets.contains(current) else { return presets }
        return (presets + [current]).sorted()
    }

    /// What a typed amount and unit come to, clamped to what the store can
    /// hold. Rounds *up* to the granularity: a floor that got rounded down
    /// would transmit sooner than the operator asked.
    static func clamp(amount: Int, unit: IntervalUnit, floor: IntervalUnit) -> Int {
        let raw = max(0, amount) * unit.seconds
        let step = floor.seconds
        let rounded = raw.isMultiple(of: step) ? raw : (raw / step + 1) * step
        return min(max(rounded, step), maximumSeconds)
    }
}

/// A pop-up of sensible intervals, with a custom editor behind it.
///
/// Bound in **seconds** whatever the setting is stored as; the
/// minutes-based initializer converts, and `granularity` keeps the editor
/// from offering a precision the store would throw away.
struct IntervalPicker: View {

    let title: String
    @Binding var seconds: Int
    /// Offered intervals, in seconds.
    var presets: [Int]
    /// The smallest unit the underlying setting can actually hold.
    var granularity: IntervalUnit = .seconds
    /// Whether zero is a legitimate value for this setting, and what to
    /// call it. Nil means the setting cannot be switched off this way.
    var offLabel: String?

    /// Tag for the Custom… entry. Negative so it can never collide with a
    /// real interval.
    private static let customTag = -1

    @State private var isEditingCustom = false
    @State private var customAmount = 1
    @State private var customUnit: IntervalUnit = .minutes

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 6) {
                Picker("", selection: menuSelection) {
                    if let offLabel {
                        Text(offLabel).tag(0)
                        Divider()
                    }
                    ForEach(IntervalFormat.options(presets: presets, current: seconds),
                            id: \.self) { option in
                        Text(IntervalFormat.label(seconds: option)).tag(option)
                    }
                    Divider()
                    Text("Custom\u{2026}").tag(Self.customTag)
                }
                .labelsHidden()
                .fixedSize()

                if isEditingCustom { customEditor }
            }
        }
    }

    private var customEditor: some View {
        HStack(spacing: 6) {
            TextField("", value: customBinding, format: .number)
                .labelsHidden()
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
#if os(iOS)
                .keyboardType(.numberPad)
#endif
            Stepper("", value: customBinding, in: 1...9999)
                .labelsHidden()
            Picker("", selection: unitBinding) {
                ForEach(IntervalFormat.units(notBelow: granularity)) { unit in
                    Text(unit.name).tag(unit)
                }
            }
            .labelsHidden()
            .fixedSize()
            Button("Done") { isEditingCustom = false }
                .buttonStyle(.borderless)
        }
        .transition(.opacity)
    }

    // MARK: - Bindings

    /// The pop-up's selection. Reads as the current interval so the menu
    /// always shows what is set — the Custom… entry is a verb, not a
    /// state, and selecting it opens the editor rather than changing the
    /// value.
    private var menuSelection: Binding<Int> {
        Binding(
            get: { seconds },
            set: { picked in
                guard picked != Self.customTag else {
                    seedCustomEditor()
                    isEditingCustom = true
                    return
                }
                isEditingCustom = false
                seconds = picked
            })
    }

    private var customBinding: Binding<Int> {
        Binding(
            get: { customAmount },
            set: { amount in
                customAmount = max(1, amount)
                writeCustom()
            })
    }

    private var unitBinding: Binding<IntervalUnit> {
        Binding(
            get: { customUnit },
            set: { unit in
                customUnit = unit
                writeCustom()
            })
    }

    private func writeCustom() {
        seconds = IntervalFormat.clamp(
            amount: customAmount, unit: customUnit, floor: granularity)
    }

    /// Opens the editor on the value already set, in the unit that value
    /// is naturally spoken in.
    private func seedCustomEditor() {
        let unit = IntervalFormat.naturalUnit(seconds: seconds, notBelow: granularity)
        customUnit = unit
        customAmount = max(1, seconds / unit.seconds)
    }
}

extension IntervalPicker {

    /// For a setting stored in whole minutes.
    init(_ title: String,
         minutes: Binding<Int>,
         presetMinutes: [Int],
         offLabel: String? = nil) {
        self.init(
            title: title,
            seconds: Binding(
                get: { minutes.wrappedValue * 60 },
                set: { minutes.wrappedValue = $0 / 60 }),
            presets: presetMinutes.map { $0 * 60 },
            granularity: .minutes,
            offLabel: offLabel)
    }

    /// For a setting stored in whole seconds.
    init(_ title: String,
         seconds: Binding<Int>,
         presetSeconds: [Int],
         offLabel: String? = nil) {
        self.init(
            title: title,
            seconds: seconds,
            presets: presetSeconds,
            granularity: .seconds,
            offLabel: offLabel)
    }
}
