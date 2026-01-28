//
//  PayloadTokenExtractor.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/30/26.
//

import Foundation

struct PayloadTokenSummary: Equatable {
    let callsigns: [String]
    let frequencies: [String]
    let urls: [String]

    var isEmpty: Bool {
        callsigns.isEmpty && frequencies.isEmpty && urls.isEmpty
    }
}

enum PayloadTokenExtractor {
    static func summarize(text: String) -> PayloadTokenSummary {
        let normalized = text.uppercased()
        let urls = extractURLs(from: text)
        let callsigns = extractCallsigns(from: normalized, excluding: urls)
        let freqs = extractFrequencies(from: text)
        return PayloadTokenSummary(
            callsigns: callsigns,
            frequencies: freqs,
            urls: urls
        )
    }

    private static func extractURLs(from text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        var urls: [String] = []
        for match in matches {
            guard let url = match.url else { continue }
            let absolute = url.absoluteString
            if !urls.contains(absolute) {
                urls.append(absolute)
            }
        }
        return urls
    }

    private static func extractCallsigns(from text: String, excluding urls: [String]) -> [String] {
        let urlSet = Set(urls.map { $0.uppercased() })
        let regex = try? NSRegularExpression(pattern: "\\b[A-Z0-9]{1,6}(?:-[0-9]{1,2})?\\b")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex?.matches(in: text, options: [], range: range) ?? []
        var callsigns: [String] = []
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range])
            guard token.rangeOfCharacter(from: .letters) != nil else { continue }
            guard !urlSet.contains(token) else { continue }
            if !callsigns.contains(token) {
                callsigns.append(token)
            }
        }
        return callsigns
    }

    private static func extractFrequencies(from text: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: "\\b\\d{2,3}\\.\\d{1,4}\\b")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex?.matches(in: text, options: [], range: range) ?? []
        var freqs: [String] = []
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range])
            if !freqs.contains(token) {
                freqs.append(token)
            }
        }
        return freqs
    }
}
