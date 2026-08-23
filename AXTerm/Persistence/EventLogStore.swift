//
//  EventLogStore.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation

nonisolated protocol EventLogStore: Sendable {
    func append(_ entry: AppEventRecord) throws
    func loadRecent(limit: Int) throws -> [AppEventRecord]
    /// Events of one category within a window, oldest first. Used to derive
    /// capture-coverage intervals from connection events.
    func loadEvents(category: AppEventRecord.Category, in window: DateInterval) throws -> [AppEventRecord]
    func deleteAll() throws
    func pruneIfNeeded(retentionLimit: Int) throws
}
