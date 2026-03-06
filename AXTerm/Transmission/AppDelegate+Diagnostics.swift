//
//  AppDelegate+Diagnostics.swift
//  AXTerm
//
//  Example of enabling AX25DiagnosticLogger at app startup.
//  Copy the appropriate code to your AppDelegate or @main App struct.
//

import SwiftUI
import AppKit

// MARK: - SwiftUI App Example

/*
 If your app uses SwiftUI's @main App struct:
 */

@main
struct AXTermApp_Example: App {
    init() {
        // Configure diagnostic logging at startup
        configureDiagnosticLogging()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Add debug menu commands
            debugMenuCommands()
        }
    }
    
    private func configureDiagnosticLogging() {
        #if DEBUG
        // Comprehensive logging for development/debugging
        AX25DiagnosticLogger.enableDebugMode()
        print("🔍 Diagnostic logging: COMPREHENSIVE mode enabled")
        #else
        // Standard logging for production
        AX25DiagnosticLogger.enableStandardMode()
        print("📊 Diagnostic logging: STANDARD mode enabled")
        #endif
    }
    
    @CommandsBuilder
    private func debugMenuCommands() -> some Commands {
        CommandMenu("Debug") {
            Button("Enable Comprehensive Logging") {
                AX25DiagnosticLogger.enableDebugMode()
            }
            .keyboardShortcut("L", modifiers: [.command, .shift])
            
            Button("Enable Standard Logging") {
                AX25DiagnosticLogger.enableStandardMode()
            }
            
            Button("Enable Minimal Logging") {
                AX25DiagnosticLogger.enableMinimalMode()
            }
            
            Divider()
            
            Button("Log Reception Summary") {
                Task {
                    // This would need the actual endpoint from your connection
                    await AX25DiagnosticLogger.shared.logInfo(
                        "User requested reception summary"
                    )
                }
            }
            
            Divider()
            
            Button("Open Console.app") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
            }
            .keyboardShortcut("C", modifiers: [.command, .option])
        }
    }
}

// MARK: - AppKit AppDelegate Example

/*
 If your app uses AppKit's AppDelegate:
 */

class AppDelegate_Example: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureDiagnosticLogging()
        setupDebugMenu()
    }
    
    private func configureDiagnosticLogging() {
        #if DEBUG
        AX25DiagnosticLogger.enableDebugMode()
        NSLog("🔍 Diagnostic logging: COMPREHENSIVE mode enabled")
        #else
        AX25DiagnosticLogger.enableStandardMode()
        NSLog("📊 Diagnostic logging: STANDARD mode enabled")
        #endif
    }
    
    private func setupDebugMenu() {
        // Add Debug menu to menu bar
        let debugMenu = NSMenu(title: "Debug")
        
        let comprehensiveItem = NSMenuItem(
            title: "Enable Comprehensive Logging",
            action: #selector(enableComprehensiveLogging),
            keyEquivalent: "l"
        )
        comprehensiveItem.keyEquivalentModifierMask = [.command, .shift]
        debugMenu.addItem(comprehensiveItem)
        
        let standardItem = NSMenuItem(
            title: "Enable Standard Logging",
            action: #selector(enableStandardLogging),
            keyEquivalent: ""
        )
        debugMenu.addItem(standardItem)
        
        let minimalItem = NSMenuItem(
            title: "Enable Minimal Logging",
            action: #selector(enableMinimalLogging),
            keyEquivalent: ""
        )
        debugMenu.addItem(minimalItem)
        
        debugMenu.addItem(NSMenuItem.separator())
        
        let consoleItem = NSMenuItem(
            title: "Open Console.app",
            action: #selector(openConsoleApp),
            keyEquivalent: "c"
        )
        consoleItem.keyEquivalentModifierMask = [.command, .option]
        debugMenu.addItem(consoleItem)
        
        let debugMenuItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugMenuItem.submenu = debugMenu
        NSApp.mainMenu?.addItem(debugMenuItem)
    }
    
    @objc private func enableComprehensiveLogging() {
        AX25DiagnosticLogger.enableDebugMode()
        showAlert("Comprehensive logging enabled", "All events will be logged with hex dumps.")
    }
    
    @objc private func enableStandardLogging() {
        AX25DiagnosticLogger.enableStandardMode()
        showAlert("Standard logging enabled", "Key events and errors will be logged.")
    }
    
    @objc private func enableMinimalLogging() {
        AX25DiagnosticLogger.enableMinimalMode()
        showAlert("Minimal logging enabled", "Only errors will be logged.")
    }
    
    @objc private func openConsoleApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
    }
    
    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Settings View Example

/*
 SwiftUI view for configuring diagnostic logging in settings:
 */

struct DiagnosticLoggingSettingsView: View {
    @State private var currentLevel: DiagnosticLevel = .standard
    @State private var showingInfo = false
    
    enum DiagnosticLevel: String, CaseIterable, Identifiable {
        case minimal = "Minimal"
        case standard = "Standard"
        case comprehensive = "Comprehensive"
        
        var id: String { rawValue }
        
        var description: String {
            switch self {
            case .minimal:
                return "Errors only (<1% overhead)"
            case .standard:
                return "Key events and errors (~2% overhead)"
            case .comprehensive:
                return "Everything with hex dumps (~5% overhead)"
            }
        }
    }
    
    var body: some View {
        Form {
            Section(header: Text("Diagnostic Logging")) {
                Picker("Log Level", selection: $currentLevel) {
                    ForEach(DiagnosticLevel.allCases) { level in
                        VStack(alignment: .leading) {
                            Text(level.rawValue)
                            Text(level.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .tag(level)
                    }
                }
                .onChange(of: currentLevel) { _, newValue in
                    applyLogLevel(newValue)
                }
                
                HStack {
                    Text("Current configuration")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(currentLevel.rawValue)
                        .fontWeight(.semibold)
                }
                
                Button("Open Console.app") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
                }
                
                Button("View Documentation") {
                    showingInfo = true
                }
                .sheet(isPresented: $showingInfo) {
                    DiagnosticLoggingInfoView()
                }
            }
        }
        .padding()
        .onAppear {
            // Detect current level (this would need actual state tracking in production)
            #if DEBUG
            currentLevel = .comprehensive
            #else
            currentLevel = .standard
            #endif
        }
    }
    
    private func applyLogLevel(_ level: DiagnosticLevel) {
        switch level {
        case .minimal:
            AX25DiagnosticLogger.enableMinimalMode()
        case .standard:
            AX25DiagnosticLogger.enableStandardMode()
        case .comprehensive:
            AX25DiagnosticLogger.enableDebugMode()
        }
    }
}

struct DiagnosticLoggingInfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Diagnostic Logging")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("AXTerm includes comprehensive diagnostic logging to help debug BLE, KISS, and AX.25 issues.")
                
                GroupBox("Viewing Logs") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Open Console.app")
                        Text("2. Filter by subsystem: com.rosswardrup.AXTerm")
                        Text("3. Filter by category: AX25Diagnostics")
                        Text("4. Look for categorized messages:")
                        Text("   • [BLE] - Bluetooth operations")
                        Text("   • [KISS] - Frame processing")
                        Text("   • [AX.25] - Protocol parsing")
                        Text("   • [Reception] - Packet timing")
                    }
                    .font(.system(.body, design: .monospaced))
                    .padding()
                }
                
                GroupBox("Log Levels") {
                    VStack(alignment: .leading, spacing: 8) {
                        levelInfo("Minimal", "Production builds - errors only", color: .green)
                        levelInfo("Standard", "Default - key events", color: .blue)
                        levelInfo("Comprehensive", "Debug - everything", color: .orange)
                    }
                    .padding()
                }
                
                GroupBox("Common Issues") {
                    VStack(alignment: .leading, spacing: 8) {
                        issueInfo("Packets stop", "Look for: ⚠️ OVERRIDE, 🚫 FILTERED, ⏱️ GAP")
                        issueInfo("Garbled data", "Look for: KISS decode errors, hex dumps")
                        issueInfo("Connection drops", "Look for: BLE service/char issues")
                    }
                    .padding()
                }
                
                Button("Open DIAGNOSTIC_LOGGING_GUIDE.md") {
                    // Open documentation file
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 600, height: 500)
    }
    
    private func levelInfo(_ name: String, _ desc: String, color: Color) -> some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .fontWeight(.semibold)
            Text("•")
                .foregroundColor(.secondary)
            Text(desc)
                .foregroundColor(.secondary)
        }
    }
    
    private func issueInfo(_ problem: String, _ solution: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(problem)
                .fontWeight(.semibold)
            Text(solution)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Connection View Integration

/*
 Example of showing diagnostic status in your connection view:
 */

struct ConnectionDebugView: View {
    @State private var showDiagnostics = false
    
    var body: some View {
        VStack {
            Toggle("Show Diagnostic Logs", isOn: $showDiagnostics)
                .onChange(of: showDiagnostics) { _, newValue in
                    if newValue {
                        AX25DiagnosticLogger.enableDebugMode()
                    } else {
                        AX25DiagnosticLogger.enableStandardMode()
                    }
                }
            
            if showDiagnostics {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                    Text("Comprehensive logging enabled. Check Console.app for details.")
                        .font(.caption)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
}

// MARK: - Usage Instructions

/*
 
 TO USE:
 
 1. Choose the appropriate example above based on your app structure
 2. Copy the init() or applicationDidFinishLaunching code
 3. Add configureDiagnosticLogging() call
 4. Optionally add the debug menu for runtime control
 5. Build and run
 6. Open Console.app to view logs
 
 The logging system is now active and will:
 - Detect characteristic override bug
 - Track reception gaps
 - Log all BLE/KISS/AX.25 events
 - Provide hex dumps for debugging
 - Monitor performance
 
 */
