//
//  NotificationSettingsView.swift
//  AXTerm
//
//  Refactored by Settings Redesign on 2/8/26.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct NotificationSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    let notificationManager: NotificationAuthorizationManager
    @EnvironmentObject var router: SettingsRouter
    
    @State private var notificationFeedback: String?
    
    // Watch List State
    @State private var selectedWatchCallsign: String?
    @State private var selectedWatchKeyword: String?
    /// Open "add" prompt, if any.
    ///
    /// A SwiftUI alert replaces the AppKit `NSAlert` this used to run: quite
    /// apart from being macOS-only, `runModal` blocks the main run loop, so
    /// the packet stream and every session timer froze behind a dialog asking
    /// for a callsign.
    @State private var prompt: TextEntryPrompt?
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        Form {
            PreferencesSection("General") {
                Toggle("Notify on Watch List hits", isOn: $settings.notifyOnWatchHits)
                    .onChange(of: settings.notifyOnWatchHits) { _, newValue in
                        if newValue {
                            Task {
                                _ = await notificationManager.requestAuthorization()
                            }
                        }
                    }
                Toggle("Play sound", isOn: $settings.notifyPlaySound)
                Toggle("Only notify when backgrounded", isOn: $settings.notifyOnlyWhenInactive)
                
                LabeledContent("Permissions") {
                    HStack {
                        Button("Open System Settings") {
                            // Each platform names its own notification pane.
                            #if os(macOS)
                            let target = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
                            #else
                            let target = URL(string: UIApplication.openSettingsURLString)
                            #endif
                            if let target { openURL(target) }
                        }
                        
                        Button("Test Notification") {
                            Task {
                                let granted = await notificationManager.requestAuthorization()
                                if granted {
                                    notificationManager.sendTestNotification()
                                } else {
                                    TxLog.error(.settings, "Notification authorization not granted", error: nil)
                                }
                            }
                        }
                    }
                }
            }
            
            PreferencesSection("Triggers") {
                Toggle("Notify when someone connects to me", isOn: $settings.notifyOnInboundConnection)
                Toggle("Notify when a node broadcasts I have mail", isOn: $settings.notifyOnNodeMail)
                Toggle("Notify when my callsign is mentioned", isOn: $settings.notifyOnMention)
            }
            
            PreferencesSection("Watch List") {
                Text("Receive notifications when specific callsigns or keywords are seen in traffic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                
                // Callsigns List
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Callsigns")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(action: addWatchCallsign) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Add callsign to watch list")
                    }
                    .padding(.bottom, 4)
                    
                    List {
                        ForEach(settings.watchCallsigns.indices, id: \.self) { index in
                             HStack {
                                Text(settings.watchCallsigns[index])
                                Spacer()
                                Button {
                                    removeWatchCallsign(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        
                        if settings.watchCallsigns.isEmpty {
                            Text("No callsigns watched")
                                .foregroundStyle(.tertiary)
                                .italic()
                        }
                    }
                    .frame(height: 120)
                    .border(Color.gray.opacity(0.2))
                }
                .padding(.bottom, 8)

                // Keywords List
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Keywords")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(action: addWatchKeyword) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Add keyword to watch list")
                    }
                    .padding(.bottom, 4)
                    
                    List {
                        ForEach(settings.watchKeywords.indices, id: \.self) { index in
                             HStack {
                                Text(settings.watchKeywords[index])
                                Spacer()
                                Button {
                                    removeWatchKeyword(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        
                        if settings.watchKeywords.isEmpty {
                            Text("No keywords watched")
                                .foregroundStyle(.tertiary)
                                .italic()
                        }
                    }
                    .frame(height: 120)
                    .border(Color.gray.opacity(0.2))
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .textEntryPrompt($prompt)
    }
    
    // MARK: - Actions
    
    private func addWatchCallsign() {
        prompt = TextEntryPrompt(
            id: "watchCallsign",
            title: "Add Watch Callsign",
            message: "Enter a callsign (e.g. K0EPI) or a wildcard (K0EPI-*). Wildcards are allowed because a watch list matches SSIDs, not licences.",
            placeholder: "N0CALL-*",
            uppercases: true) { call in
                settings.watchCallsigns.append(call)
            }
    }

    private func removeWatchCallsign(at index: Int) {
        settings.watchCallsigns.remove(at: index)
    }

    private func addWatchKeyword() {
        prompt = TextEntryPrompt(
            id: "watchKeyword",
            title: "Add Watch Keyword",
            message: "Enter a keyword to watch for in packet text. Matching is case-insensitive.",
            placeholder: "Emergency") { keyword in
                settings.watchKeywords.append(keyword)
            }
    }

    private func removeWatchKeyword(at index: Int) {
        settings.watchKeywords.remove(at: index)
    }
}
