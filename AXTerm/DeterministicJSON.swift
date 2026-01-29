//
//  DeterministicJSON.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation

enum DeterministicJSON {
    nonisolated static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func encodeDictionary(_ value: [String: String]) -> String? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func decodeDictionary(_ value: String) -> [String: String]? {
        guard let data = value.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return object
    }
}
