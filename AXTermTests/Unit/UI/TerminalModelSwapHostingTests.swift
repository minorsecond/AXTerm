//
//  TerminalModelSwapHostingTests.swift
//  AXTermTests
//
//  The terminal's view model is held above the view (TerminalModelBox) and
//  is replaced when the station's callsign changes. Test mode starts with no
//  callsign, so on the live RF test of 2026-09-30 both stations set theirs
//  with the terminal already on screen and got a fresh model. The view only
//  wired its callbacks in onAppear, which does not run again for a new model,
//  so the frame-sent and ack notices kept going to the old one: a chat
//  message acked at the link layer read "Queued" with "Sending…" in the
//  header for good, and an inbound session never became the terminal's own
//  (bugs 2 and 4).
//
//  These host the real TerminalView off screen, swap the model the way
//  ContentView does, and check the new model hears what the old one used to.
//

#if os(macOS)
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class TerminalModelSwapHostingTests: XCTestCase {

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

    /// Bug 2. The operator sets the callsign, the model is replaced, a chat
    /// message goes out and the peer's RR acks it. The message must read as
    /// sent and then delivered.
    func testAReplacedModelHearsSendsAndAcks() {
        let station = makeStation("TerminalModelSwapAcks")
        defer { station.window.close() }

        let model = station.makeModel(sourceCall: "K0EPI-2")
        station.holder.model = model
        spin(0.5)

        model.destinationCall.wrappedValue = "K0EPI-3"
        model.startOutboundProgress(text: "A to B test 1", totalBytes: 14, destination: "K0EPI-3",
                                    hasAcks: true, startingVs: 0, paclen: 128)
        XCTAssertEqual(model.currentOutboundProgress?.deliveryPhase, .queued)

        // The I-frame reaches the TNC.
        station.client.onUserFrameTransmitted?(14)
        XCTAssertEqual(model.currentOutboundProgress?.bytesSent, 14,
                       "the frame went out but the message still reads Queued")

        // The peer's RR acks it.
        let session = station.coordinator.sessionManager.session(for: AX25Address(call: "K0EPI", ssid: 3))
        station.coordinator.sessionManager.onOutboundAckReceived?(session, 1)
        settle { model.currentOutboundProgress?.deliveryPhase == .delivered }
        XCTAssertEqual(model.currentOutboundProgress?.deliveryPhase, .delivered,
                       "the link-layer ack never reached the model on screen")
        withExtendedLifetime(station) {}
    }

    /// Bug 4. A peer connects to us after the model was replaced. The
    /// terminal has to pick the session up, or Send stays disabled until the
    /// operator finds the session in the sidebar.
    func testAReplacedModelAdoptsAnInboundSession() {
        let station = makeStation("TerminalModelSwapInbound")
        defer { station.window.close() }

        let model = station.makeModel(sourceCall: "K0EPI-3")
        station.holder.model = model
        spin(0.5)

        let manager = station.coordinator.sessionManager
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 3)
        _ = manager.handleInboundSABM(from: AX25Address(call: "K0EPI", ssid: 2),
                                      to: AX25Address(call: "K0EPI", ssid: 3),
                                      path: DigiPath(), radio: .primary)
        settle { model.sessionState == .connected }
        XCTAssertEqual(model.sessionState, .connected)
        XCTAssertEqual(model.viewModel.destinationCall, "K0EPI-2")
        withExtendedLifetime(station) {}
    }
}
#endif
