//
//  NumericInput.swift
//  AXTerm
//
//  Created by Settings UX Fixes on 2/8/26.
//

import SwiftUI

/// A numeric input field that handles local string state to prevent "snap back" issues.
/// Commits only valid integers within the specified range to the binding.
struct NumericInput: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    
    @State private var textValue: String
    @FocusState private var isFocused: Bool
    
    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int> = 0...Int.max, step: Int = 1) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self._textValue = State(initialValue: String(value.wrappedValue))
    }
    
    var body: some View {
        HStack(spacing: 8) {
            TextField(title, text: $textValue)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .frame(width: 80) // Fixed width for numeric inputs usually suffices in settings
                #if os(macOS)
                .onExitCommand {
                    // Revert on Escape
                    textValue = String(value)
                    isFocused = false
                }
                #endif
                .onChange(of: isFocused) { _, focused in
                    if focused {
                        // On focus, ensure text matches current value
                        textValue = String(value)
                    } else {
                        // On blur, commit validation
                        commit()
                    }
                }
                .onSubmit {
                    commit()
                }
                .onChange(of: value) { _, newValue in
                    // If the external value changes (e.g. via Stepper), update text ONLY if not currently editing
                    if !isFocused {
                        textValue = String(newValue)
                    }
                }
            
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
    
    private func commit() {
        // Filter non-numeric characters (allow negative if range supports it, though usually settings are unsigned)
        let filtered = textValue.filter { "0123456789-".contains($0) }
        
        if let newValue = Int(filtered) {
            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
            value = clamped
            textValue = String(clamped)
        } else {
            // Invalid/Empty input: revert to last valid value
            textValue = String(value)
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State var val = 8001
        var body: some View {
            Form {
                NumericInput("Port", value: $val, range: 1...65535)
            }
            .padding()
        }
    }
    return PreviewWrapper()
}
