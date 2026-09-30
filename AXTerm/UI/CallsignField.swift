//
//  CallsignField.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/8/26.
//

import SwiftUI

/// A specialized TextField for entering an amateur radio callsign.
/// Upper-cases as the operator types (see `callsignInput`) and flags a
/// value that is not a callsign.
struct CallsignField: View {
    let title: String
    @Binding var text: String
    @State private var isFocused: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
             // The setter only trims; callsignInput upper-cases, which
             // it cannot do from here without iOS keeping the lower case
             // on screen.
             TextField(title, text: Binding(
                 get: { text },
                 set: { text = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
             ))
             .textFieldStyle(.roundedBorder)
             .callsignInput($text)
             
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
