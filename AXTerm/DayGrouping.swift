//
//  DayGrouping.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation
import SwiftUI

nonisolated struct DayGroupedSection<Item: Identifiable>: Identifiable {
    let id: String
    let date: Date
    let items: [Item]
}

nonisolated enum DayGrouping {
    static func group<Item: Identifiable>(
        items: [Item],
        date: (Item) -> Date,
        calendar: Calendar = .current
    ) -> [DayGroupedSection<Item>] {
        guard !items.isEmpty else { return [] }
        var sections: [DayGroupedSection<Item>] = []
        var currentDate = date(items[0])
        var currentItems: [Item] = []

        func flushSection() {
            let id = dayKey(for: currentDate, calendar: calendar)
            sections.append(DayGroupedSection(id: id, date: currentDate, items: currentItems))
        }

        for item in items {
            let itemDate = date(item)
            if calendar.isDate(itemDate, inSameDayAs: currentDate) {
                currentItems.append(item)
            } else {
                flushSection()
                currentDate = itemDate
                currentItems = [item]
            }
        }
        flushSection()
        return sections
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let start = calendar.startOfDay(for: date)
        return String(start.timeIntervalSince1970)
    }
}

struct DaySeparatorView: View {
    let date: Date
    var calendar: Calendar = .current

    var body: some View {
        HStack(spacing: 8) {
            Divider()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var label: String {
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
