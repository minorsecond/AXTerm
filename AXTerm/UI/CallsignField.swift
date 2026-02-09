//
//  CallsignField.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/8/26.
//

import SwiftUI

/// A specialized TextField for entering an amateur radio callsign.
/// Handles auto-capitalization, validation feedback, and SSID formatting.
struct CallsignField: View {
    let title: String
    @Binding var text: String
    @State private var isFocused: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
             TextField(title, text: Binding(
                 get: { text },
                 set: { text = CallsignValidator.normalize($0) }
             ))
             .textFieldStyle(.roundedBorder)
             .disableAutocorrection(true)
             #if os(iOS)
             .textInputAutocapitalization(.characters)
             #endif
             .onChange(of: text) { _, newValue in
                 // Additional side-effects if needed
             }
             
             if !text.isEmpty && !CallsignValidator.isValidCallsign(text) {
                 HStack(spacing: 4) {
                     Image(systemName: "exclamationmark.triangle.fill")
                     Text("Invalid format (e.g. K0EPI-7)")
                 }
                 .font(.caption)
                 .foregroundStyle(.red)
             }
        }
    }
}
