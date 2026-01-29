//
//  CallsignValidator.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import Foundation

enum CallsignValidator {
    private static let callsignPattern = "^[A-Z0-9]{1,6}(?:-[0-9]{1,2})?$"

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func isValid(_ value: String) -> Bool {
        let normalized = normalize(value)
        guard !normalized.isEmpty else { return false }
        guard normalized.rangeOfCharacter(from: .letters) != nil else { return false }
        return normalized.range(of: callsignPattern, options: [.regularExpression]) != nil
    }
}
