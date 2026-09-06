import Foundation

/// What the mailbox lists when the operator asks to see every instance.
///
/// Pure, so the rules are testable: this mailbox first, then one section per
/// other mailbox, never interleaved; nothing from elsewhere unless asked;
/// every remote row labelled with whose mailbox it is. The filter applies to
/// both sides with *this* operator as the sysop — mail left for them on the
/// iPad's mailbox is still theirs.
nonisolated enum BBSUnifiedListing {

    struct RemoteOrigin: Equatable, Hashable, Sendable {
        var mailbox: String
        var station: String
        var deviceID: String
        var deviceName: String?
        var gridSquare: String?

        var deviceTitle: String {
            SessionHistoryListing.deviceTitle(name: deviceName, deviceID: deviceID)
        }
    }

    enum Origin: Equatable, Hashable, Sendable {
        case thisMailbox
        case otherMailbox(RemoteOrigin)

        /// The words on the row. Nil for this mailbox.
        var label: String? {
            switch self {
            case .thisMailbox:
                return nil
            case .otherMailbox(let origin):
                let device = origin.deviceName ?? "device \(WinlinkSyncDevice.shortName(origin.deviceID))"
                return "From \(origin.mailbox)\u{2019}s mailbox on \(device)"
            }
        }
    }

    struct MessageRow: Identifiable, Equatable, Sendable {
        var id: String
        var message: BBSMessage
        var origin: Origin
    }

    struct CallRow: Identifiable, Equatable, Sendable {
        var id: String
        var call: BBSCall
        var origin: Origin
    }

    struct Section<Row: Identifiable & Equatable & Sendable>: Identifiable, Equatable, Sendable {
        var id: String
        var title: String?
        var attribution: String?
        var isRemote: Bool
        var rows: [Row]
    }

    static let thisMailboxTitle = "This mailbox"

    // MARK: Messages

    static func messageSections(local: [BBSMessage],
                                remote: [BBSMessagePayload],
                                showsOtherInstances: Bool,
                                filter: BBSMessageFilter,
                                sysop: String) -> [Section<MessageRow>] {
        let localRows = BBSMessageList.visible(local, filter: filter, sysop: sysop)
            .map { MessageRow(id: "local|\($0.id)", message: $0, origin: .thisMailbox) }

        var remoteSections: [Section<MessageRow>] = []
        if showsOtherInstances {
            remoteSections = Dictionary(grouping: remote, by: \.provenance.deviceID)
                .compactMap { deviceID, payloads -> Section<MessageRow>? in
                    guard let newest = payloads.max(by: { $0.receivedAt < $1.receivedAt }) else { return nil }
                    let origin = RemoteOrigin(mailbox: newest.mailbox, station: newest.provenance.station,
                                              deviceID: deviceID, deviceName: newest.deviceName,
                                              gridSquare: newest.provenance.gridSquare)
                    let byID = Dictionary(payloads.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                    let rows = BBSMessageList.visible(payloads.map(\.message), filter: filter, sysop: sysop)
                        .map { message in
                            MessageRow(id: "\(deviceID)|\(message.id)", message: message,
                                       origin: .otherMailbox(byID[message.id].map { _ in origin } ?? origin))
                        }
                    guard !rows.isEmpty else { return nil }
                    return Section(id: deviceID, title: origin.deviceTitle,
                                   attribution: attribution(for: origin), isRemote: true, rows: rows)
                }
                .sorted { $0.title!.localizedCaseInsensitiveCompare($1.title!) == .orderedAscending }
        }

        var sections: [Section<MessageRow>] = []
        if !localRows.isEmpty {
            sections.append(Section(id: "local",
                                    title: remoteSections.isEmpty ? nil : thisMailboxTitle,
                                    attribution: nil, isRemote: false, rows: localRows))
        }
        return sections + remoteSections
    }

    // MARK: Calls

    static func callSections(local: [BBSCall],
                             remote: [BBSCallPayload],
                             showsOtherInstances: Bool) -> [Section<CallRow>] {
        let localRows = local
            .sorted { $0.connectedAt > $1.connectedAt }
            .map { CallRow(id: "local|\($0.id)", call: $0, origin: .thisMailbox) }

        var remoteSections: [Section<CallRow>] = []
        if showsOtherInstances {
            remoteSections = Dictionary(grouping: remote, by: \.provenance.deviceID)
                .compactMap { deviceID, payloads -> Section<CallRow>? in
                    guard let newest = payloads.max(by: { $0.disconnectedAt < $1.disconnectedAt }) else { return nil }
                    let origin = RemoteOrigin(mailbox: newest.mailbox, station: newest.provenance.station,
                                              deviceID: deviceID, deviceName: newest.deviceName,
                                              gridSquare: newest.provenance.gridSquare)
                    let rows = payloads
                        .sorted { $0.connectedAt > $1.connectedAt }
                        .map { CallRow(id: "\(deviceID)|\($0.id)", call: $0.call, origin: .otherMailbox(origin)) }
                    return Section(id: deviceID, title: origin.deviceTitle,
                                   attribution: attribution(for: origin), isRemote: true, rows: rows)
                }
                .sorted { $0.title!.localizedCaseInsensitiveCompare($1.title!) == .orderedAscending }
        }

        var sections: [Section<CallRow>] = []
        if !localRows.isEmpty {
            sections.append(Section(id: "local",
                                    title: remoteSections.isEmpty ? nil : thisMailboxTitle,
                                    attribution: nil, isRemote: false, rows: localRows))
        }
        return sections + remoteSections
    }

    // MARK: Words

    /// The sentence under a remote heading: whose mailbox, on which device,
    /// where. "K0EPI-9's mailbox on iPad · DM79".
    static func attribution(for origin: RemoteOrigin) -> String {
        var line = "\(origin.mailbox)\u{2019}s mailbox on \(origin.deviceTitle)"
        if let grid = origin.gridSquare, !grid.isEmpty { line += " \u{b7} \(grid)" }
        return line
    }

    static func countLine(local: Int, remote: Int, noun: String) -> String {
        var line = local == 1 ? "1 \(noun)" : "\(local) \(noun)s"
        if remote == 1 {
            line += " \u{b7} 1 from another mailbox"
        } else if remote > 1 {
            line += " \u{b7} \(remote) from other mailboxes"
        }
        return line
    }
}
