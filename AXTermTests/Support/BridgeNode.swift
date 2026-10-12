import Foundation
@testable import AXTerm

/// A node the way BPQ behaves from a caller's terminal: it answers a call,
/// greets with its prompt, and on `C <call>` opens its own link to that
/// station and pipes bytes both ways, untouched, saying "Connected to" when
/// the far station answers. The far station sees a call from the node's
/// callsign (a BPQ downlink). Built on a real `TransferStation`, with its
/// sessions claimed so its own terminal and AXDP never see the traffic.
@MainActor
final class BridgeNode {
    let station: TransferStation
    let alias: String
    private var callerSession: AX25Session?
    private var farSession: AX25Session?
    private var claims: [SessionDeliveryClaim] = []
    private var lineBuffer = Data()
    private var token: UUID?
    /// What the node said to the caller, for assertions.
    private(set) var toCaller = Data()

    init(station: TransferStation, alias: String) {
        self.station = station
        self.alias = alias
        station.coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = false
        token = station.coordinator.addInboundSessionSubscriber { [weak self] session in
            self?.answered(session)
        }
    }

    private var prompt: String { "\(alias):\(station.callsign)} " }

    private func answered(_ session: AX25Session) {
        callerSession = session
        if let claim = station.coordinator.sessionManager.claimDelivery(for: session.key, handler: { [weak self] _, data in
            self?.fromCaller(data)
        }) {
            claims.append(claim)
        }
        send(Data("\(prompt)BPQ-style test node\r".utf8), on: session)
    }

    private func fromCaller(_ data: Data) {
        if let farSession, farSession.state == .connected {
            send(data, on: farSession)
            return
        }
        lineBuffer.append(data)
        while let end = lineBuffer.firstIndex(of: 0x0D) {
            let line = String(decoding: lineBuffer[lineBuffer.startIndex..<end], as: UTF8.self)
            lineBuffer.removeSubrange(lineBuffer.startIndex...end)
            let words = line.split(separator: " ")
            if words.count == 2, words[0].uppercased() == "C" {
                dial(String(words[1]))
            }
        }
    }

    private func dial(_ call: String) {
        let address = CallsignNormalizer.toAddress(call)
        let manager = station.coordinator.sessionManager
        guard let frame = manager.connect(to: address, path: DigiPath(), radio: station.coordinator.primaryRadioID)
        else { return }
        station.coordinator.sendFrame(frame)
        let key = SessionKey(destination: address, path: DigiPath(), radio: station.coordinator.primaryRadioID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await manager.awaitConnectionOutcome(key: key, timeout: 10)
            guard case .connected = outcome, let far = manager.session(atKey: key), let caller = self.callerSession
            else { return }
            self.farSession = far
            if let claim = manager.claimDelivery(for: far.key, handler: { [weak self] _, data in
                guard let caller = self?.callerSession else { return }
                self?.send(data, on: caller)
            }) {
                self.claims.append(claim)
            }
            self.send(Data("\(self.prompt)Connected to \(address.display)\r".utf8), on: caller)
        }
    }

    private func send(_ data: Data, on session: AX25Session) {
        if session === callerSession { toCaller.append(data) }
        for frame in station.coordinator.sessionManager.sendData(data, to: session.remoteAddress, path: session.path,
                                                                 radio: session.radio) {
            station.coordinator.sendFrame(frame)
        }
    }
}
