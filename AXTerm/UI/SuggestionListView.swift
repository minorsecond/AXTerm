import SwiftUI

struct SuggestionListSection<Item: Identifiable & Hashable>: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [Item]
}

struct SuggestionListView<Item: Identifiable & Hashable, RowContent: View>: View {
    let sections: [SuggestionListSection<Item>]
    @Binding var highlightedItemID: Item.ID?
    let onSelect: (Item) -> Void
    let rowContent: (Item, Bool) -> RowContent

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)

                        ForEach(section.items) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                rowContent(item, highlightedItemID == item.id)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 6)
                            .onHover { hovering in
                                if hovering {
                                    highlightedItemID = item.id
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 260)
    }
}
