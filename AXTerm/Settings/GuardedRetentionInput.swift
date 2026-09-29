//
//  GuardedRetentionInput.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/8/26.
//

import SwiftUI

/// A text field that buffers input and requires confirmation before reducing a numeric value.
/// Used for retention settings to prevent accidental database pruning during typing.
struct GuardedRetentionInput: View {
    let title: String
    @Binding var value: Int
    let min: Int
    let max: Int
    let step: Int
    
    @State private var tempValue: String = ""
    @State private var showingReductionAlert = false
    @State private var pendingValue: Int?
    @FocusState private var isFocused: Bool
    
    init(title: String = "", value: Binding<Int>, min: Int, max: Int, step: Int = 1000) {
        self.title = title
        self._value = value
        self.min = min
        self.max = max
        self.step = step
        self._tempValue = State(initialValue: String(value.wrappedValue))
    }
    
    var body: some View {
        HStack(spacing: 8) {
            TextField(
                title,
                text: $tempValue
            )
            .frame(width: 80)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit {
                commitValue()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commitValue()
                } else {
                    // Reset temp value to current actual value when focusing
                    // to ensure we start fresh if it was changed externally
                    tempValue = String(value)
                }
            }
            // Update temp value if external value changes while not focused
            .onChange(of: value) { _, newValue in
                if !isFocused {
                    tempValue = String(newValue)
                }
            }
            
            Stepper(
                "",
                value: Binding(
                    get: { value },
                    set: { newValue in
                        handleStepperChange(newValue)
                    }
                ),
                in: min...max,
                step: step
            )
            .labelsHidden()
        }
        .alert(
            "Reduce Retention Limit?",
            isPresented: $showingReductionAlert,
            actions: {
                Button("Reduce & Prune", role: .destructive) {
                    if let newValue = pendingValue {
                        value = newValue
                        tempValue = String(newValue)
                    }
                    pendingValue = nil
                }
                Button("Cancel", role: .cancel) {
                    tempValue = String(value)
                    pendingValue = nil
                }
            },
            message: {
                Text("Reducing the retention limit will permanently delete older data. This cannot be undone.")
            }
        )
    }
    
    private func commitValue() {
        // Parse the input
        guard let newValue = Int(tempValue) else {
            // Invalid input, revert
            tempValue = String(value)
            return
        }
        
        let clampedValue = Swift.max(min, Swift.min(max, newValue))
        
        // If value hasn't changed effectively, just format it
        if clampedValue == value {
            tempValue = String(value)
            return
        }
        
        // Check if we are reducing the limit
        if clampedValue < value {
            pendingValue = clampedValue
            showingReductionAlert = true
        } else {
            // Increasing or same, just apply
            value = clampedValue
            tempValue = String(clampedValue)
        }
    }
    
    // Steppers bypassing the text field buffer need similar protection
    private func handleStepperChange(_ newValue: Int) {
        if newValue < value {
            pendingValue = newValue
            showingReductionAlert = true
        } else {
            value = newValue
            tempValue = String(newValue)
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State var limit = 50000
        
        var body: some View {
            Form {
                HStack {
                    Text("Retention")
                    Spacer()
                    GuardedRetentionInput(
                        value: $limit,
                        min: 1000,
                        max: 100000
                    )
                }
            }
            .padding()
        }
    }
    return PreviewWrapper()
}
