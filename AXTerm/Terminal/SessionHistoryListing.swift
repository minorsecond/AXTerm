import Foundation

/// What the History screen lists, in what order, under which headings.
///
/// Pure, so the rules are testable without a view: local sessions first,
/// then one section per other device, never interleaved; every remote row
/// says where it came from; nothing remote unless the operator asked. The
/// labelling is the safety feature — a transcript from the home rig sitting
/// unmarked in the iPad's list would read as something the iPad did.
nonisolated enum SessionHistoryListing {

    /// Where a remote row came from, as much of it as is known.
    struct RemoteOrigin: Equatable, Hashable, Sendable {
        var station: String
        var deviceID: String
        var deviceName: String?
        var gridSquare: String?
        var transcriptTruncated: Bool

        /// "Ross's Mac", or "Device 0F9E8D7C" when the device gave no name.
        var deviceTitle: String {
            SessionHistoryListing.deviceTitle(name: deviceName, deviceID: deviceID)
        }
    }

    enum Origin: Equatable, Hashable, Sendable {
        case thisDevice
        case otherDevice(RemoteOrigin)

        /// The words on the row. Nil for this device: it is the default, and
        /// a label on every row would make the remote label mean nothing.
        var label: String? {
            switch self {
            case .thisDevice:
                return nil
            case .otherDevice(let origin):
                let device = origin.deviceName ?? "device \(WinlinkSyncDevice.shortName(origin.deviceID))"
                return "From \(origin.station) on \(device)"
            }
        }
    }

    struct Row: Identifiable, Equatable, Sendable {
        /// Distinct across origins even for the same session ID.
        var id: String
        var session: TerminalSession
        var origin: Origin
    }

    struct Section: Identifiable, Equatable, Sendable {
        var id: String
        /// Nil when the list is only this device's and needs no heading.
        var title: String?
        /// The sentence under a remote heading saying whose sessions these are.
        var attribution: String?
        var isRemote: Bool
        var rows: [Row]
    }

    static let thisDeviceTitle = "This device"

    static func deviceTitle(name: String?, deviceID: String) -> String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return "Device \(WinlinkSyncDevice.shortName(deviceID))"
    }

    /// Builds the sections.
    ///
    /// - Parameters:
    ///   - tag: a tag filter. Tags are local annotations, so a tag filter
    ///     shows only local rows carrying it rather than pretending remote
    ///     rows have tags.
    static func sections(local: [TerminalSession],
                         remote: [TerminalSessionPayload],
                         showsOtherDevices: Bool,
                         query: String,
                         tag: String?) -> [Section] {
        let localRows = local
            .filter { session in
                if let tag, !session.tags.contains(tag) { return false }
                return session.matches(query)
            }
            .map { Row(id: $0.id.uuidString, session: $0, origin: .thisDevice) }

        var remoteSections: [Section] = []
        if showsOtherDevices, tag == nil {
            let byDevice = Dictionary(grouping: remote, by: \.provenance.deviceID)
            remoteSections = byDevice.compactMap { deviceID, payloads -> Section? in
                let ordered = payloads.sorted { $0.endedAt > $1.endedAt }
                let rows = ordered
                    .filter { $0.session.matches(query) }
                    .map { payload in
                        Row(id: "\(deviceID)|\(payload.id.uuidString)",
                            session: payload.session,
                            origin: .otherDevice(RemoteOrigin(
                                station: payload.provenance.station,
                                deviceID: deviceID,
                                deviceName: payload.deviceName,
                                gridSquare: payload.provenance.gridSquare,
                                transcriptTruncated: payload.transcriptTruncated)))
                    }
                guard !rows.isEmpty, let newest = ordered.first else { return nil }
                let title = deviceTitle(name: newest.deviceName, deviceID: deviceID)
                var attribution = "Connected from \(newest.provenance.station) on \(title)"
                if let grid = newest.provenance.gridSquare, !grid.isEmpty {
                    attribution += " \u{b7} \(grid)"
                }
                return Section(id: deviceID, title: title, attribution: attribution,
                               isRemote: true, rows: rows)
            }
            .sorted { $0.title!.localizedCaseInsensitiveCompare($1.title!) == .orderedAscending }
        }

        var sections: [Section] = []
        if !localRows.isEmpty {
            sections.append(Section(
                id: "local",
                title: remoteSections.isEmpty ? nil : thisDeviceTitle,
                attribution: nil, isRemote: false, rows: localRows))
        }
        sections += remoteSections
        return sections
    }

    /// Says what is shown against what is stored, so a filter never quietly
    /// hides history, and how much of what is shown is not this device's.
    static func countLine(shown: Int, total: Int, remoteShown: Int) -> String {
        var line: String
        if shown == total {
            line = total == 1 ? "1 session" : "\(total) sessions"
        } else {
            line = "\(shown) of \(total) sessions"
        }
        if remoteShown == 1 {
            line += " \u{b7} 1 from another device"
        } else if remoteShown > 1 {
            line += " \u{b7} \(remoteShown) from other devices"
        }
        return line
    }
}
