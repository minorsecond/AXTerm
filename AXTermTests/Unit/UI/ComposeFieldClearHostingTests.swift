#if os(macOS)
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class ComposeFieldClearHostingTests: XCTestCase {

    private final class Holder: ObservableObject {
        @Published var model: ObservableTerminalTxViewModel
        init(_ model: ObservableTerminalTxViewModel) { self.model = model }
    }

    private struct Root: View {
        @ObservedObject var holder: Holder
        let client: PacketEngine
        let settings: AppSettingsStore
        let coordinator: SessionCoordinator
        let connectCoordinator: ConnectCoordinator
        let aliases: NodeAliasStore
        let search: AppToolbarSearchModel

        var body: some View {
            TerminalView(client: client, settings: settings, sessionCoordinator: coordinator,
                         connectCoordinator: connectCoordinator, nodeAliases: aliases,
                         txViewModel: holder.model, searchModel: search)
        }
    }

    @MainActor
    private struct Station {
        let settings: AppSettingsStore
        let client: PacketEngine
        let coordinator: SessionCoordinator
        let holder: Holder
        let window: NSWindow

        func makeModel(sourceCall: String) -> ObservableTerminalTxViewModel {
            ObservableTerminalTxViewModel(client: client, settings: settings, sourceCall: sourceCall,
                                          sessionManager: coordinator.sessionManager)
        }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func settle(timeout: TimeInterval = 2, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { spin(0.05) }
    }

    /// A station with no callsign yet, as test mode starts, its terminal on
    /// screen.
    private func makeStation(_ label: String) -> Station {
        let defaults = TestDefaults.make(label)
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        for radio in settings.radios {
            settings.updateRadio(radio.id) {
                $0.enabled = false
                $0.host = "127.0.0.1"
                $0.port = 9
            }
        }
        let client = PacketEngine(settings: settings)
        let coordinator = SessionCoordinator()
        let first = ObservableTerminalTxViewModel(client: client, settings: settings, sourceCall: "",
                                                  sessionManager: coordinator.sessionManager)
        let holder = Holder(first)
        let root = Root(holder: holder, client: client, settings: settings, coordinator: coordinator,
                        connectCoordinator: ConnectCoordinator(), aliases: NodeAliasStore(),
                        search: AppToolbarSearchModel())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        spin(0.5)
        return Station(settings: settings, client: client, coordinator: coordinator,
                       holder: holder, window: window)
    }


    private func textFields(in view: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        if let f = view as? NSTextField, f.placeholderString == "Message" { out.append(f) }
        for sub in view.subviews { out += textFields(in: sub) }
        return out
    }

    /// A sent line leaves the message field empty for good. Return sends with
    /// the field still being edited; the send cleared the draft and the text
    /// on screen, but the field kept the line as its value, and when the link
    /// dropped and the field was disabled it showed that line again over an
    /// empty draft. Return then did nothing and Send sent a blank line (smoke
    /// run 2026-10-03-1, issue 77).
    func testASentLineDoesNotComeBackWhenTheLinkDrops() throws {
        let station = makeStation("ComposeFieldClear")
        defer { station.window.close() }
        let model = station.makeModel(sourceCall: "K0EPI-2")
        station.holder.model = model
        station.client.setStatusForTesting(.connected)
        station.window.makeKeyAndOrderFront(nil)
        spin(0.5)
        let manager = station.coordinator.sessionManager
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 2)
        let peer = AX25Address(call: "K0EPI", ssid: 3)
        _ = manager.handleInboundSABM(from: peer, to: AX25Address(call: "K0EPI", ssid: 2),
                                      path: DigiPath(), radio: .primary)
        settle { model.sessionState == .connected }
        spin(0.5)

        let field = try XCTUnwrap(textFields(in: station.window.contentView!).first)
        XCTAssertTrue(station.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(station.window.fieldEditor(false, for: field) as? NSTextView)
        editor.insertText("N", replacementRange: editor.selectedRange())
        spin(0.3)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            NSApp.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: station.window.windowNumber, context: nil,
                                             characters: "\r", charactersIgnoringModifiers: "\r",
                                             isARepeat: false, keyCode: 36)!)
        }
        spin(0.5)
        XCTAssertEqual(model.viewModel.composeText, "", "the line was sent")
        // Only a key window can take focus, and under a parallel test run
        // another test's window can hold key status.
        if station.window.isKeyWindow {
            let focused = (station.window.firstResponder as? NSTextView)?.delegate as? NSTextField
            XCTAssertTrue(focused === textFields(in: station.window.contentView!).first,
                          "the cursor is back in the box for the next line")
        }
        // Not read here: asking a field being edited for its value commits the
        // editor's text and hides the fault.

        _ = manager.handleInboundDISC(from: peer, path: DigiPath(), radio: .primary)
        spin(1.0)
        let shown = textFields(in: station.window.contentView!).first?.stringValue
        XCTAssertEqual(shown, "", "the sent line came back on screen over an empty draft")
        withExtendedLifetime(station) {}
    }
}
#endif
