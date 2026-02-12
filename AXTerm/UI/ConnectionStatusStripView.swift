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
    
    private var isConnected: Bool {
        sessionState == .connected
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
                } else {
                    disconnectedStatusView()
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        }
        .frame(maxWidth: .infinity)
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
    
    // MARK: - Disconnected Status
    
    @ViewBuilder
    private func disconnectedStatusView() -> some View {
        HStack(spacing: 6) {
            // Gray status dot - muted, no animation
            Circle()
                .fill(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 8, height: 8)
            
            // "Not connected" - subheadline, clearly not connected state
            Text("Not connected")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            
            // Hint if TNC not connected
            if !isTNCConnected {
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