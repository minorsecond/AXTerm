//
//  ConnectionStatusStripView.swift
//  AXTerm
//
//  Compact, always-visible connection status strip for terminal view
//

import SwiftUI

/// Compact, always-visible connection status strip that summarizes current connection state
/// while keeping SYS messages in the log for full detail.
struct ConnectionStatusStripView: View {
    let session: AX25Session?
    let sessionState: AX25SessionState?
    let destinationCall: String
    let viaDigipeaters: [String]
    let connectionMode: ConnectBarMode
    let isTNCConnected: Bool
    /// Hop-by-hop position of a node-prompt relay, when one is walking a
    /// chain. Empty for every ordinary connect.
    var relayHops: [NetRomRelayProgress.Hop] = []
    
    private var isConnected: Bool {
        sessionState == .connected
    }

    private var isConnecting: Bool {
        sessionState == .connecting
    }

    private var isDisconnecting: Bool {
        sessionState == .disconnecting
    }
    
    private var linkModeText: String {
        switch connectionMode {
        case .ax25:
            return "AX.25"
        case .ax25ViaDigi:
            return "AX.25"
        case .netrom:
            return "NET/ROM"
        default:
            return "AX.25"
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Connection strip background
            HStack(spacing: 12) {
                if isConnected, let session = session {
                    connectedStatusView(session: session)
                } else if isConnecting {
                    connectingStatusView()
                } else if isDisconnecting {
                    transientStatusView(label: "Disconnecting")
                } else {
                    disconnectedStatusView()
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(platform: .platformCardBackground).opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Relay hop progress

    /// You 🔗 DRLNOD 🔗 KB5YZB-7 (spinner) COSCO › ASHCHT — the answer to
    /// "which node is being negotiated with right now", read off the relay's
    /// own phase so it cannot drift from what the relay is doing.
    ///
    /// The connector carries the state, not the node: what a hop produces
    /// is a *link made* between two stations, so a made segment shows a
    /// chain link, the segment being negotiated shows a spinner, and one
    /// not yet attempted stays a dim chevron.
    private var relayProgressRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                Text("You")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                ForEach(relayHops) { hop in
                    relayEdge(into: hop)
                    Text(hop.name)
                        .font(hop.state == .active ? .caption.weight(.semibold) : .caption)
                        .foregroundStyle(hop.state == .pending ? .tertiary : .primary)
                        .help(relayHopHelp(hop))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(relayAccessibilitySummary)
    }

    @ViewBuilder
    private func relayEdge(into hop: NetRomRelayProgress.Hop) -> some View {
        switch hop.state {
        case .done:
            Image(systemName: "link")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .help("The link to \(hop.name) is made.")
        case .active:
            ProgressView()
                .controlSize(.mini)
                .help("Negotiating the link to \(hop.name) right now.")
        case .pending:
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
    }

    private func relayHopHelp(_ hop: NetRomRelayProgress.Hop) -> String {
        switch hop.state {
        case .done: return "\(hop.name) is on the chain — the link to it is made."
        case .active: return "Negotiating with \(hop.name) right now."
        case .pending: return "\(hop.name) has not been linked yet."
        }
    }

    private var relayAccessibilitySummary: String {
        guard let active = relayHops.first(where: { $0.state == .active }) else {
            return "Relay chain complete"
        }
        let done = relayHops.filter { $0.state == .done }.count
        return "Relay progress: negotiating with \(active.name), "
            + "\(done) of \(relayHops.count) hops made"
    }
    
    // MARK: - Connected Status
    
    @ViewBuilder
    private func connectedStatusView(session: AX25Session) -> some View {
        HStack(spacing: 6) {
            // Status dot - vertically aligned with text baseline
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
            
            // Callsign - title3 semibold, not oversized
            Text(destinationCall.isEmpty ? "Connected" : destinationCall)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            
            // Subcaption - subheadline, clearly metadata
            HStack(spacing: 4) {
                Text("·")
                    .foregroundStyle(.tertiary)
                
                // Link mode badge
                Text(linkModeText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                
                if !viaDigipeaters.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    
                    Text("via \(viaDigipeaters.joined(separator: " → "))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                if let srtt = session.timers.srtt {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    
                    Text("RTT \(String(format: "%.1fs", srtt))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Text("·")
                    .foregroundStyle(.tertiary)
                
                Text("K: \(session.stateMachine.config.windowSize)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                if session.statistics.retransmissions > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    
                    Text("\(session.statistics.retransmissions) retries")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
    }
    
    // MARK: - Connecting / Disconnecting Status

    @ViewBuilder
    private func connectingStatusView() -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)

            Text(destinationCall.isEmpty ? "Connecting" : "Connecting to \(destinationCall)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 4) {
                Text("\u{00B7}")
                    .foregroundStyle(.tertiary)

                Text(linkModeText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                if !relayHops.isEmpty {
                    // A relay walking a chain: the hop map says everything
                    // "via <node>" would and more, on the same line.
                    Text("\u{00B7}")
                        .foregroundStyle(.tertiary)
                    relayProgressRow
                } else if !viaDigipeaters.isEmpty {
                    Text("\u{00B7}")
                        .foregroundStyle(.tertiary)

                    Text("via \(viaDigipeaters.joined(separator: " \u{2192} "))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let session, session.statistics.retransmissions > 0 {
                    Text("\u{00B7}")
                        .foregroundStyle(.tertiary)

                    Text("try \(session.statistics.retransmissions + 1)")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func transientStatusView(label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)

            Text(destinationCall.isEmpty ? label : "\(label) \(destinationCall)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    // MARK: - Disconnected Status
    
    @ViewBuilder
    private func disconnectedStatusView() -> some View {
        HStack(spacing: 6) {
            // Gray status dot - muted, no animation
            Circle()
                .fill(Color(platform: .platformTertiaryLabel))
                .frame(width: 8, height: 8)
            
            // "Not connected" - subheadline, clearly not connected state
            Text("Not connected")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            
            // Hint when TNC is ready but no session is active
            if isTNCConnected {
                Text("·")
                    .foregroundStyle(.tertiary)

                Text("Select a station and Connect")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            
            Spacer()
        }
    }
}