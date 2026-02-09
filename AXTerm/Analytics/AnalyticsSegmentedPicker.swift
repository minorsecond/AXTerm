//
//  AnalyticsSegmentedPicker.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-09.
//

import SwiftUI
import AppKit

/// A custom segmented control that supports individual tooltips on macOS,
/// which the native Picker with .segmented style does not reliably do.
struct AnalyticsSegmentedPicker<T: Hashable & Identifiable>: View {
    @Binding var selection: T
    let items: any RandomAccessCollection<T>
    let label: (T) -> String
    let tooltip: (T) -> String
    
    var body: some View {
        HStack(spacing: 0) {
            let itemsArray = Array(items)
            ForEach(0..<itemsArray.count, id: \.self) { index in
                let item = itemsArray[index]
                let isSelected = selection == item
                
                Text(label(item))
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .frame(minWidth: 40)
                    .background(isSelected ? Color.accentColor : Color.clear)
                    .foregroundColor(isSelected ? .white : .primary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = item
                    }
                    .help(tooltip(item))
                
                if index < itemsArray.count - 1 && !isSelected && (index + 1 < itemsArray.count && selection != itemsArray[index + 1]) {
                    Divider()
                        .frame(height: 12)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
        .cornerRadius(5)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
        .fixedSize()
    }
}
