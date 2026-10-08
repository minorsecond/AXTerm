import SwiftUI

/// What a sort key compares, which decides how its two directions read.
nonisolated enum SortKind: Sendable {
    case time, text, size
}

/// One column a list of files or messages can be sorted by.
nonisolated protocol ListSortKey: CaseIterable, Hashable, Sendable, RawRepresentable
where RawValue == String, AllCases: RandomAccessCollection {
    var title: String { get }
    var kind: SortKind { get }
}

/// How a list of files or messages is sorted: by which key, which way
/// (operator, 2026-10-07). Stored as a string so `@AppStorage` keeps each
/// list's choice.
nonisolated struct ListSort<Key: ListSortKey>: Hashable, Sendable, RawRepresentable {
    var key: Key
    var ascending: Bool

    init(key: Key, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// The way a key is usually wanted first: newest, A to Z, largest.
    static func natural(_ key: Key) -> ListSort {
        ListSort(key: key, ascending: key.kind == .text)
    }

    var rawValue: String { key.rawValue + (ascending ? ".asc" : ".desc") }

    init?(rawValue: String) {
        guard let dot = rawValue.lastIndex(of: ".") else { return nil }
        let direction = rawValue[rawValue.index(after: dot)...]
        guard let key = Key(rawValue: String(rawValue[..<dot])),
              direction == "asc" || direction == "desc" else { return nil }
        self.init(key: key, ascending: direction == "asc")
    }

    /// "Newest First", "A to Z", "Largest First".
    static func orderTitle(kind: SortKind, ascending: Bool) -> String {
        switch (kind, ascending) {
        case (.time, true): return "Oldest First"
        case (.time, false): return "Newest First"
        case (.text, true): return "A to Z"
        case (.text, false): return "Z to A"
        case (.size, true): return "Smallest First"
        case (.size, false): return "Largest First"
        }
    }

    var orderTitle: String { Self.orderTitle(kind: key.kind, ascending: ascending) }

    /// Sorted by `value`, this way. Stable, so items that compare equal
    /// keep the order they came in.
    func sorted<T, V: Comparable>(_ items: [T], by value: (T) -> V) -> [T] {
        sorted(items) { value($0) < value($1) }
    }

    /// Text in the order Finder uses: case-insensitive, numbers by value.
    func sorted<T>(_ items: [T], text: (T) -> String) -> [T] {
        sorted(items) { text($0).localizedStandardCompare(text($1)) == .orderedAscending }
    }

    private func sorted<T>(_ items: [T], less: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { a, b in
            if less(a.element, b.element) { return ascending }
            if less(b.element, a.element) { return !ascending }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// The sort control every list uses: a key, then a direction worded for it.
struct ListSortMenu<Key: ListSortKey>: View {
    @Binding var sort: ListSort<Key>

    var body: some View {
        Menu {
            Picker("Sort By", selection: Binding(
                get: { sort.key },
                set: { sort = ListSort.natural($0) })) {
                ForEach(Array(Key.allCases), id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            Picker("Order", selection: $sort.ascending) {
                Text(ListSort<Key>.orderTitle(kind: sort.key.kind, ascending: sort.key.kind == .text))
                    .tag(sort.key.kind == .text)
                Text(ListSort<Key>.orderTitle(kind: sort.key.kind, ascending: sort.key.kind != .text))
                    .tag(sort.key.kind != .text)
            }
        } label: {
            Label("Sort: \(sort.key.title), \(sort.orderTitle)", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sorted by \(sort.key.title.lowercased()), \(sort.orderTitle.lowercased())")
    }
}
