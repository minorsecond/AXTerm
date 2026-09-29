//
//  RawEntryRecord.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation
import GRDB

nonisolated struct RawEntryRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "raw_entries"

    enum Kind: String, Codable {
        case frame
        case bytes
        case error
    }

    var id: UUID
    var createdAt: Date
    var source: String
    var direction: String
    var kind: Kind
    var rawHex: String
    var byteCount: Int
    var packetID: UUID?
    var metadataJSON: String?

    func toRawChunk() -> RawChunk {
        let data = PacketEncoding.decodeHex(rawHex)
        return RawChunk(id: id, timestamp: createdAt, data: data)
    }
}
