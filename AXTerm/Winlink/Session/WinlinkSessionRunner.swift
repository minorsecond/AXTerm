import Foundation
import Combine

/// Drives one Winlink mail exchange: pumps bytes between a transport and
/// the `B2FSessionEngine`, executes engine actions (sends, timers,
/// persistence), and reports progress for the UI.
///
/// The engine owns the protocol; the runner owns IO, wall clocks, and
/// the store. Per AXTERM-TRANSMISSION-SPEC §7.8 the underlying AX.25
/// session's parameters are fixed at creation — the runner never touches
/// them.
@MainActor
final class WinlinkSessionRunner: ObservableObject {

    enum Phase: Equatable {
        case idle
        case preparing
        case connecting
        case exchanging
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusText: String = ""
    @Published private(set) var lastSummary: WinlinkExchangeSummary?
    /// Live byte-level progress for the progress card (nil when idle).
    @Published private(set) var progress: WinlinkExchangeProgress?

    // Per-message metadata and delivery baselines for send progress.
    private var messageSubjects: [String: String] = [:]
    private var messageCompressedSizes: [String: Int] = [:]
    private var lastDeliveredBytes = 0
    private var lastSubmittedBytes = 0
    private var sendBaselineBytes = 0

    private let worker: WinlinkPersistenceWorker
    private var engine: B2FSessionEngine?
    private var transport: WinlinkTransport?
    private var timerTasks: [B2FSessionEngine.TimerKind: Task<Void, Never>] = [:]
    private var completion: CheckedContinuation<WinlinkExchangeSummary, Never>?
    private var startedAt = Date()
    /// Bytes handed to the transport since the last timer was armed; used
    /// to stretch protocol timeouts over slow RF links (1200 bd moves
    /// ~100 B/s of payload — a 30 kB attachment takes minutes).
    private var bytesQueuedSinceTimer = 0
    /// Conservative effective link throughput used for timeout stretching.
    private let assumedBytesPerSecond: Int

    var isRunning: Bool {
        phase == .preparing || phase == .connecting || phase == .exchanging
    }

    init(store: WinlinkStore, assumedBytesPerSecond: Int = 50) {
        self.worker = WinlinkPersistenceWorker(store: store)
        self.assumedBytesPerSecond = max(1, assumedBytesPerSecond)
    }

    // MARK: - Public entry points

    /// Runs a full exchange over `transport`. Returns the session summary
    /// (also published as `lastSummary`).
    @discardableResult
    func runExchange(
        transport: WinlinkTransport,
        myCallsign: String,
        password: String?,
        gatewayName: String,
        transportName: String,
        sid: WinlinkSID? = nil
    ) async -> WinlinkExchangeSummary {
        guard !isRunning else {
            var summary = WinlinkExchangeSummary()
            summary.failureReason = "an exchange is already running"
            return summary
        }

        phase = .preparing
        statusText = "Preparing outbound mail…"
        startedAt = Date()
        bytesQueuedSinceTimer = 0

        // Compress queued mail off the main actor — LZHUF is CPU work.
        let queued = (try? await worker.queuedOutboundMessages()) ?? []
        let prepared: [B2FSessionEngine.PreparedOutbound]
        do {
            prepared = try await Task.detached(priority: .userInitiated) {
                try queued.map { message in
                    let encoded = try message.encode()
                    return B2FSessionEngine.PreparedOutbound(
                        message: message,
                        compressed: LZHUF.encodeB2F(encoded),
                        uncompressedSize: encoded.count)
                }
            }.value
        } catch {
            return await finish(failure: "failed to encode outbound mail: \(error)",
                                gatewayName: gatewayName, transportName: transportName)
        }

        let engine = B2FSessionEngine(config: .init(
            myCallsign: myCallsign,
            password: password,
            sid: sid ?? .axterm(version: Self.appVersion),
            outbound: prepared))
        self.engine = engine
        self.transport = transport

        transport.onReceive = { [weak self] data in
            self?.dispatch(.bytesReceived(data))
        }
        transport.onClose = { [weak self] _ in
            self?.dispatch(.linkDisconnected)
        }
        transport.onDeliveryProgress = { [weak self] delivered, submitted in
            self?.handleDeliveryProgress(delivered: delivered, submitted: submitted)
        }

        messageSubjects = Dictionary(uniqueKeysWithValues: prepared.map { ($0.message.mid, $0.message.subject) })
        messageCompressedSizes = Dictionary(uniqueKeysWithValues: prepared.map { ($0.message.mid, $0.compressed.count) })
        lastDeliveredBytes = 0
        lastSubmittedBytes = 0
        sendBaselineBytes = 0

        phase = .connecting
        statusText = "Connecting to \(gatewayName)…"
        progress = WinlinkExchangeProgress(kind: .connecting, startedAt: Date())
        do {
            try await transport.open()
        } catch {
            transport.onClose = nil
            return await finish(failure: "connect failed: \(describeTransportError(error))",
                                gatewayName: gatewayName, transportName: transportName)
        }

        phase = .exchanging
        statusText = "Signing in to \(gatewayName)…"
        progress = WinlinkExchangeProgress(kind: .handshake, startedAt: Date())

        let summary = await withCheckedContinuation { (continuation: CheckedContinuation<WinlinkExchangeSummary, Never>) in
            self.completion = continuation
            self.dispatch(.connected)
        }

        return await finish(summary: summary, gatewayName: gatewayName, transportName: transportName)
    }

    /// Requests a polite abort of the running exchange.
    func abort() {
        guard isRunning else { return }
        dispatch(.abortRequested)
    }

    // MARK: - Engine pump

    private var eventQueue: [B2FSessionEngine.Event] = []
    private var isDispatching = false

    private func dispatch(_ event: B2FSessionEngine.Event) {
        // Serialize: a transport that echoes synchronously must not
        // re-enter the engine while an action list is still executing.
        eventQueue.append(event)
        guard !isDispatching else { return }
        isDispatching = true
        defer { isDispatching = false }

        while !eventQueue.isEmpty {
            let next = eventQueue.removeFirst()
            guard let engine else { break }
            for action in engine.handle(next) {
                perform(action)
            }
        }
    }

    private func perform(_ action: B2FSessionEngine.Action) {
        switch action {
        case .send(let data):
            bytesQueuedSinceTimer += data.count
            transport?.send(data)

        case .startTimer(let kind, let seconds):
            // Stretch protocol timeouts by the time our own queued bytes
            // still need on the air; the peer cannot answer sooner.
            let stretched = seconds + bytesQueuedSinceTimer / assumedBytesPerSecond
            bytesQueuedSinceTimer = 0
            startTimer(kind, seconds: min(stretched, 1800))

        case .cancelTimer(let kind):
            timerTasks[kind]?.cancel()
            timerTasks[kind] = nil

        case .outboundAccepted(let mid, let offset):
            statusText = "Sending \(mid)…"
            // Everything submitted before this body (handshake, proposals,
            // earlier messages) sits below this baseline, so the bar counts
            // exactly this message's bytes as they are acked.
            sendBaselineBytes = lastSubmittedBytes
            let total = max(0, (messageCompressedSizes[mid] ?? 0) - offset)
            progress = WinlinkExchangeProgress(
                kind: .sending, mid: mid, subject: messageSubjects[mid],
                bytesDone: 0, bytesTotal: total, startedAt: Date())
            Task { [worker] in
                try? await worker.markSending(mid: mid)
                if offset > 0 { try? await worker.recordSentOffset(mid: mid, offset: offset) }
            }

        case .outboundBodySent(let mid):
            statusText = "Waiting for the link to drain \(mid)…"

        case .outboundRejected(let mid):
            Task { [worker] in
                try? await worker.markFailed(mid: mid, error: "rejected by the gateway")
            }

        case .outboundDeferred(let mid):
            Task { [worker] in
                try? await worker.markDeferred(mid: mid)
            }

        case .messageFullyReceived(let message, _):
            statusText = "Received \(message.mid)"
            Task { [worker] in
                try? await worker.saveInbound(message)
            }

        case .receiveProgress(let mid, let bytes, let total):
            statusText = "Receiving \(mid)…"
            if progress?.kind == .receiving, progress?.mid == mid {
                progress?.bytesDone = bytes
                progress?.bytesTotal = total
            } else {
                progress = WinlinkExchangeProgress(
                    kind: .receiving, mid: mid, bytesDone: bytes, bytesTotal: total, startedAt: Date())
            }

        case .requestDisconnect:
            transport?.close()

        case .complete(let summary):
            resolve(with: summary)

        case .fail(let reason):
            var summary = engineSummaryForFailure(reason: reason)
            summary.failureReason = reason
            resolve(with: summary)
        }
    }

    private func engineSummaryForFailure(reason: String) -> WinlinkExchangeSummary {
        var summary = WinlinkExchangeSummary()
        summary.failureReason = reason
        return summary
    }

    /// Feeds L2 ack (or socket-write) totals into the current send bar.
    private func handleDeliveryProgress(delivered deliveredBytes: Int, submitted submittedBytes: Int) {
        lastDeliveredBytes = deliveredBytes
        lastSubmittedBytes = submittedBytes
        guard var current = progress, current.kind == .sending, current.bytesTotal > 0 else { return }
        current.bytesDone = max(0, min(current.bytesTotal, deliveredBytes - sendBaselineBytes))
        progress = current
    }

    private func resolve(with summary: WinlinkExchangeSummary) {
        cancelAllTimers()
        completion?.resume(returning: summary)
        completion = nil
    }

    private func startTimer(_ kind: B2FSessionEngine.TimerKind, seconds: Int) {
        timerTasks[kind]?.cancel()
        timerTasks[kind] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dispatch(.timerFired(kind))
        }
    }

    private func cancelAllTimers() {
        for task in timerTasks.values { task.cancel() }
        timerTasks.removeAll()
    }

    // MARK: - Finalization

    private func finish(failure reason: String, gatewayName: String, transportName: String) async -> WinlinkExchangeSummary {
        var summary = WinlinkExchangeSummary()
        summary.failureReason = reason
        return await finish(summary: summary, gatewayName: gatewayName, transportName: transportName)
    }

    private func finish(summary: WinlinkExchangeSummary, gatewayName: String, transportName: String) async -> WinlinkExchangeSummary {
        cancelAllTimers()
        transport?.onReceive = nil
        transport?.onClose = nil
        transport?.onDeliveryProgress = nil
        progress = nil

        // Persist final delivery states. Anything still marked `sending`
        // (session died mid-body) reverts to `queued`; only offsets the
        // server confirmed are trusted for resume.
        for mid in summary.sentMIDs {
            try? await worker.markSent(mid: mid)
        }
        try? await worker.revertSendingToQueued()

        let log = WinlinkSessionLogRecord(
            id: nil,
            startedAt: startedAt,
            endedAt: Date(),
            gatewayCallsign: gatewayName,
            transport: transportName,
            result: summary.failureReason ?? (summary.aborted ? "aborted" : "success"),
            messagesSent: summary.sentMIDs.count,
            messagesReceived: summary.receivedMIDs.count,
            bytesSent: summary.bytesSent,
            bytesReceived: summary.bytesReceived,
            errorText: summary.failureReason)
        try? await worker.appendSessionLog(log)

        engine = nil
        transport = nil
        lastSummary = summary

        if let reason = summary.failureReason {
            phase = .failed(reason)
            statusText = reason
        } else {
            phase = .done
            statusText = summaryStatusText(summary)
        }
        return summary
    }

    private func summaryStatusText(_ summary: WinlinkExchangeSummary) -> String {
        let sent = summary.sentMIDs.count
        let received = summary.receivedMIDs.count
        if sent == 0 && received == 0 { return "No new mail." }
        var parts = [String]()
        if sent > 0 { parts.append("sent \(sent)") }
        if received > 0 { parts.append("received \(received)") }
        return "Exchange complete: " + parts.joined(separator: ", ") + "."
    }

    private func describeTransportError(_ error: Error) -> String {
        switch error {
        case WinlinkTransportError.sessionBusy(let detail): return "session busy — \(detail)"
        case WinlinkTransportError.connectRefused(let station): return "\(station) refused the connection"
        case WinlinkTransportError.connectTimeout(let station): return "no response from \(station)"
        case WinlinkTransportError.loginFailed(let detail): return detail
        default: return String(describing: error)
        }
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}
