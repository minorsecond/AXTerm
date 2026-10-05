//
//  WinlinkP2PAnswerer.swift
//  AXTerm
//

import Foundation

/// Answers inbound calls as a peer-to-peer Winlink mail station when the
/// operator has armed it (Settings, Winlink, "Answer inbound Winlink
/// calls").
///
/// Owned by the station's services, so it answers whether or not the Mail
/// page has been opened. It lived in the Mail page until 2026-10-05: a
/// station launched straight to its terminal said "Armed", accepted the
/// link and never greeted the caller (smoke run 2026-10-03-1, issue 61).
///
/// Every decision is logged to the exchange console: a station that
/// silently ignores callers is indistinguishable from a broken one.
@MainActor
final class WinlinkP2PAnswerer {
    private let coordinator: SessionCoordinator
    private let context: WinlinkContext
    private let settings: AppSettingsStore
    private weak var client: PacketEngine?

    init(coordinator: SessionCoordinator, context: WinlinkContext,
         settings: AppSettingsStore, client: PacketEngine) {
        self.coordinator = coordinator
        self.context = context
        self.settings = settings
        self.client = client
    }

    /// Takes the coordinator's inbound-session slot.
    func attach() {
        coordinator.onInboundSessionConnected = { [weak self] session in
            Task { @MainActor [weak self] in
                await self?.inboundSessionConnected(session)
            }
        }
    }

    private func inboundSessionConnected(_ session: AX25Session) async {
        let winlinkSettings = context.settings
        let listener = WinlinkP2PListener(
            isArmed: winlinkSettings.p2pListenEnabled,
            myCallsign: winlinkSettings.effectiveP2PCallsign(
                stationCallsign: settings.primaryCallsign),
            isExchangeRunning: context.runner?.isRunning ?? true,
            // Refuses to answer when another of the operator's devices
            // already holds this callsign on this TNC — otherwise both
            // reply to the same caller with nobody watching.
            contestedBy: context.contestedIdentityHolder,
            runningExchangePeer: context.runner?.currentPeer)
        let decision = listener.decide(
            called: session.localAddress.display, isInitiator: session.isInitiator,
            caller: session.remoteAddress.display)
        if decision == .answerWhenFree {
            context.runner?.note(
                "Inbound call from \(session.remoteAddress.display): \(decision.explanation)")
            guard await context.runner?.waitUntilIdle(timeout: 15) == true,
                  session.state == .connected else {
                context.runner?.note(
                    "Did not answer \(session.remoteAddress.display) again: the old exchange did not close in time or the link went down")
                return
            }
            await answer(session)
            return
        }
        guard decision == .answer else {
            if case .weInitiated = decision { return }
            context.runner?.note(
                "Inbound call from \(session.remoteAddress.display) \(decision.explanation)")
            return
        }
        await answer(session)
    }

    private func answer(_ session: AX25Session) async {
        guard let runner = context.runner else { return }
        let peer = session.remoteAddress.display.uppercased()
        // The transport reuses the already-connected session rather than
        // placing a call: `open()` finds it and returns immediately.
        let transport = WinlinkAX25Transport(
            sessionManager: coordinator.sessionManager,
            sendFrames: { [weak client] frames in
                for frame in frames { client?.send(frame: frame) }
            },
            destination: session.remoteAddress,
            radio: session.radio)
        _ = await runner.runExchange(
            transport: transport,
            myCallsign: settings.myCallsign,
            password: nil,          // P2P carries no CMS account
            gatewayName: peer,
            transportName: "P2P",
            role: .answering,
            peer: peer)
        // The Mail page refreshes its lists from this.
        context.exchangeFinished()
    }
}
