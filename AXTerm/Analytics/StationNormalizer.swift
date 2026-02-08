//
//  StationNormalizer.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-18.
//

import Foundation

enum StationNormalizer {
    static func normalize(_ station: String?) -> String? {
        guard let station else { return nil }
        let trimmed = station.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "?" else { return nil }
        return trimmed.uppercased()
    }
}
