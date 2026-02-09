//
//  FilterPillView.swift
//  AXTerm
//
//  Created by Antigravity on 2/9/26.
//

import SwiftUI

struct FilterPillView: View {
    let label: String
    let value: String
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text(value)
                .font(.caption.bold())
                .foregroundStyle(.primary)
            
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help("Clear \(label.lowercased()) filter")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

#Preview {
    HStack {
        FilterPillView(label: "Station", value: "K0NTS-7", onDismiss: {})
        FilterPillView(label: "Search", value: "BBS", onDismiss: {})
    }
    .padding()
}
