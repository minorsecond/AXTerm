//
//  MainView.swift
//  AXTerm
//
//  The main view for the application, containing the session UI and other components.
//

import SwiftUI

struct MainView: View {
    @ObservedObject private var settings = AppSettingsStore()
    @State private var isConnected = false
    @State private var connectedCallsign: String = ""
    @State private var viaPath: String = ""
    @State private var rtt: Double = 0.0

    // Mock data for demonstration purposes
    init() {
        self.isConnected = true
        self.connectedCallsign = "NOHI-7"
        self.viaPath = "WOARP-7"
        self.rtt = 4.5
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Area
            HStack(alignment: .center, spacing: 8) {
                Text(connectedCallsign)
                    .font(.largeTitle.bold())
                
                Circle()
                    .fill(isConnected ? Color.green : Color.gray)
                    .frame(width: 12, height: 12)
                
                VStack(alignment: .leading, spacing: 0) {
                    if isConnected {
                        Text("AX.25 · via \(viaPath) · RTT \(String(format: "%.1f", rtt))s")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Not connected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(UIColor.systemBackground))
            .shadow(radius: 2)

            // Main Content Area
            Spacer()

            // Bottom Bar (placeholder for now)
            HStack {
                Text("Session: \(connectedCallsign) | AX.25: Digi: \(viaPath)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
    }
}
