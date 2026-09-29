//
//  ConsoleStore.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation

nonisolated protocol ConsoleStore: Sendable {
    func append(_ entry: ConsoleEntryRecord) throws
    func loadRecent(limit: Int) throws -> [ConsoleEntryRecord]
    func deleteAll() throws
    func pruneIfNeeded(retentionLimit: Int) throws
}
