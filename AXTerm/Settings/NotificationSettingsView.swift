//
//  NotificationSettingsView.swift
//  AXTerm
//
//  Refactored by Settings Redesign on 2/8/26.
//

import SwiftUI

struct NotificationSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    let notificationManager: NotificationAuthorizationManager
    @EnvironmentObject var router: SettingsRouter
    
    @State private var notificationFeedback: String?
    
    // Watch List State
    @State private var selectedWatchCallsign: String?
    @State private var selectedWatchKeyword: String?
    
    var body: some View {
        Form {
            PreferencesSection("General") {
                Toggle("Notify on Watch List hits", isOn: $settings.notifyOnWatchHits)
                Toggle("Play sound", isOn: $settings.notifyPlaySound)
                Toggle("Only notify when backgrounded", isOn: $settings.notifyOnlyWhenInactive)
                
                LabeledContent("Permissions") {
                    HStack {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        
                        Button("Test Notification") {
                            notificationManager.sendTestNotification()
                        }
                    }
                }
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
    }
    
    // MARK: - Actions
    
    private func addWatchCallsign() {
        let alert = NSAlert()
        alert.messageText = "Add Watch Callsign"
        alert.informativeText = "Enter a callsign (e.g. K0EPI) or wildcard (K0EPI-*)."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "N0CALL-*"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        
        if alert.runModal() == .alertFirstButtonReturn {
            let call = input.stringValue.trimmingCharacters(in: .whitespaces).uppercased()
            if !call.isEmpty {
                // Basic validation or just add?
                // For watch lists, we allow wildcards, so strictly speaking calls might not be valid Callsign objects
                settings.watchCallsigns.append(call)
            }
        }
    }
    
    private func removeWatchCallsign(at index: Int) {
        settings.watchCallsigns.remove(at: index)
    }
    
    private func addWatchKeyword() {
        let alert = NSAlert()
        alert.messageText = "Add Watch Keyword"
        alert.informativeText = "Enter a keyword to watch for in packet text."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "Emergency"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        
        if alert.runModal() == .alertFirstButtonReturn {
            let keyword = input.stringValue.trimmingCharacters(in: .whitespaces)
            if !keyword.isEmpty {
                settings.watchKeywords.append(keyword)
            }
        }
    }
    
    private func removeWatchKeyword(at index: Int) {
        settings.watchKeywords.remove(at: index)
    }
}
