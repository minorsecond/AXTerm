import Foundation

nonisolated enum ConnectBarState: Equatable {
    case disconnectedDraft(ConnectDraft)
    case connecting(ConnectDraft)
    case connectedSession(SessionInfo)
    case disconnecting(SessionInfo)
    case broadcastComposer(BroadcastComposerState)
    case failed(ConnectDraft, ConnectFailure)

    var isDraftEditable: Bool {
        switch self {
        case .disconnectedDraft, .failed:
            return true
        case .connecting, .connectedSession, .disconnecting, .broadcastComposer:
            return false
        }
    }

    var isSessionActive: Bool {
        switch self {
        case .connecting, .connectedSession, .disconnecting:
            return true
        case .disconnectedDraft, .broadcastComposer, .failed:
            return false
        }
    }
}

nonisolated struct ConnectDraft: Equatable {
    var sourceContext: ConnectSourceContext
    var destination: String
    var transport: ConnectTransportDraft

    static func empty(context: ConnectSourceContext = .terminal) -> ConnectDraft {
        ConnectDraft(sourceContext: context, destination: "", transport: .ax25(.direct))
    }

    var normalizedDestination: String {
        CallsignValidator.normalize(destination)
    }

    var summaryLine: String {
        switch transport {
        case let .ax25(option):
            switch option {
            case .direct:
                return "AX.25 direct"
            case let .viaDigipeaters(path):
                if path.isEmpty { return "AX.25 direct" }
                return "AX.25 via \(path.joined(separator: ", "))"
            }
        case let .netrom(option):
            if let nextHop = option.forcedNextHop, !nextHop.isEmpty {
                return "NET/ROM via \(nextHop) (forced)"
            }
            return "NET/ROM auto route"
        }
    }
}

nonisolated enum ConnectTransportDraft: Equatable {
    case ax25(AX25DraftOptions)
    case netrom(NetRomDraftOptions)
}

nonisolated enum AX25DraftOptions: Equatable {
    case direct
    case viaDigipeaters([String])
}

nonisolated struct NetRomDraftOptions: Equatable {
    var forcedNextHop: String?
    var routePreview: String?
}

nonisolated struct SessionInfo: Equatable {
    let sourceContext: ConnectSourceContext
    let sourceCall: String?
    let destination: String
    let transport: SessionTransport
    let connectedAt: Date

    var summaryLine: String {
        switch transport {
        case let .ax25(via):
            if via.isEmpty { return "AX.25 direct" }
            return "AX.25 via \(via.joined(separator: ", "))"
        case let .netrom(nextHop, forced):
            if forced, let nextHop, !nextHop.isEmpty {
                return "NET/ROM via \(nextHop) (forced)"
            }
            if let nextHop, !nextHop.isEmpty {
                return "NET/ROM via \(nextHop)"
            }
            return "NET/ROM auto route"
        }
    }
}

nonisolated enum SessionTransport: Equatable {
    case ax25(via: [String])
    case netrom(nextHop: String?, forced: Bool)
}

nonisolated struct BroadcastComposerState: Equatable {
    var unprotoPath: [String]
    var remembersLastUsedPath: Bool

    static let `default` = BroadcastComposerState(unprotoPath: [], remembersLastUsedPath: true)
}

nonisolated struct ConnectFailure: Equatable {
    nonisolated enum Reason: Equatable {
        case invalidDraft
        case noRoute
        case tncDisconnected
        case connectRejected
        case timeout
        case unknown
    }

    let reason: Reason
    let detail: String?
}

nonisolated struct SidebarStationSelection: Equatable {
    let callsign: String
    let context: ConnectSourceContext
    let lastUsedMode: ConnectBarMode?
    let hasNetRomRoute: Bool
}

nonisolated enum SidebarConnectAction: Equatable {
    case prefill
    case connect
}

nonisolated enum ConnectBarEvent: Equatable {
    case switchedToBroadcast
    case switchedToConnect
    case draftUpdated(ConnectDraft)
    case connectRequested(ConnectDraft)
    case connectSucceeded(SessionInfo)
    case connectFailed(ConnectFailure)
    case disconnectRequested
    case disconnectCompleted(nextDraft: ConnectDraft)
    case sidebarSelection(SidebarStationSelection, SidebarConnectAction)
}

nonisolated enum ConnectBarStateReducer {
    static func reduce(state: ConnectBarState, event: ConnectBarEvent) -> ConnectBarState {
        switch (state, event) {
        case let (_, .switchedToBroadcast):
            return .broadcastComposer(.default)

        case let (.broadcastComposer, .switchedToConnect):
            return .disconnectedDraft(.empty())

        case let (.disconnectedDraft(_), .draftUpdated(draft)),
             let (.failed(_, _), .draftUpdated(draft)):
            return .disconnectedDraft(draft)

        case let (.disconnectedDraft(_), .connectRequested(draft)),
             let (.failed(_, _), .connectRequested(draft)):
            return .connecting(draft)

        case let (.connecting(_), .connectSucceeded(session)):
            return .connectedSession(session)

        case let (.connecting(draft), .connectFailed(error)):
            return .failed(draft, error)

        case let (.connectedSession(session), .disconnectRequested):
            return .disconnecting(session)

        case let (.disconnecting(_), .disconnectCompleted(nextDraft)):
            return .disconnectedDraft(nextDraft)

        case let (.disconnectedDraft(_), .sidebarSelection(selection, action)),
             let (.failed(_, _), .sidebarSelection(selection, action)):
            let mode = preferredMode(for: selection)
            let draft = draftFromSidebar(selection: selection, mode: mode)
            switch action {
            case .prefill:
                return .disconnectedDraft(draft)
            case .connect:
                return .connecting(draft)
            }

        default:
            return state
        }
    }

    private static func preferredMode(for selection: SidebarStationSelection) -> ConnectBarMode {
        if let remembered = selection.lastUsedMode {
            return remembered
        }
        return selection.hasNetRomRoute ? .netrom : .ax25
    }

    private static func draftFromSidebar(selection: SidebarStationSelection, mode: ConnectBarMode) -> ConnectDraft {
        let normalized = CallsignValidator.normalize(selection.callsign)
        switch mode {
        case .ax25:
            return ConnectDraft(sourceContext: selection.context, destination: normalized, transport: .ax25(.direct))
        case .ax25ViaDigi:
            return ConnectDraft(sourceContext: selection.context, destination: normalized, transport: .ax25(.viaDigipeaters([])))
        case .netrom:
            return ConnectDraft(sourceContext: selection.context, destination: normalized, transport: .netrom(NetRomDraftOptions(forcedNextHop: nil, routePreview: nil)))
        }
    }
}
