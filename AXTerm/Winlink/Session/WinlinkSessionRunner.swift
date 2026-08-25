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
    /// Rolling wire transcript for the popdown exchange console.
    @Published private(set) var transcript: [WinlinkTranscriptEntry] = []
    private static let transcriptLimit = 600

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
    private var sessionFrequencyHz: Int?
    /// Bytes handed to the transport since the last timer was armed; used
    /// to stretch protocol timeouts over slow RF links (1200 bd moves
    /// ~100 B/s of payload — a 30 kB attachment takes minutes).
    private var bytesQueuedSinceTimer = 0
    /// Conservative effective link throughput used for timeout stretching.
    private let assumedBytesPerSecond: Int

    /// Where the operator is. Resolved in the background at exchange start
    /// so the session log can record where this link was measured from —
    /// never awaited on the path to keying the radio.
    private let observationProvider: (@MainActor () async -> StationLocation?)?
    private var observedLocation: StationLocation?
    private var observationTask: Task<Void, Never>?

    var isRunning: Bool {
        phase == .preparing || phase == .connecting || phase == .exchanging
    }

    init(
        store: WinlinkStore,
        assumedBytesPerSecond: Int = 50,
        observationProvider: (@MainActor () async -> StationLocation?)? = nil
    ) {
        self.worker = WinlinkPersistenceWorker(store: store)
        self.assumedBytesPerSecond = max(1, assumedBytesPerSecond)
        self.observationProvider = observationProvider
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
        frequencyHz: Int? = nil,
        sid: WinlinkSID? = nil,
        role: B2FSessionEngine.Role = .initiator,
        preserveTranscript: Bool = false
    ) async -> WinlinkExchangeSummary {
        guard !isRunning else {
            var summary = WinlinkExchangeSummary()
            summary.failureReason = "an exchange is already running"
            return summary
        }

        phase = .preparing
        statusText = "Preparing outbound mail…"
        startedAt = Date()
        sessionFrequencyHz = frequencyHz
        bytesQueuedSinceTimer = 0
        // Fire and forget: a GPS fix takes seconds, the exchange takes
        // minutes, and the answer is only needed when the log is written.
        observedLocation = nil
        observationTask?.cancel()
        if let observationProvider {
            observationTask = Task { [weak self] in
                let location = await observationProvider()
                guard !Task.isCancelled else { return }
                self?.observedLocation = location
            }
        }
        if !preserveTranscript {
            transcript.removeAll()
        }
        log(.event, role == .answering
            ? "Answering \(gatewayName) — \(transportName)"
            : "Exchange started — \(transportName) via \(gatewayName)")

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

        // Partially received bodies from interrupted sessions: offer the
        // gateway a resume offset instead of downloading from scratch.
        let partials = (try? await worker.partialBodies()) ?? []
        let partialInbound = Dictionary(uniqueKeysWithValues: partials.map {
            ($0.mid, B2FSessionEngine.PartialInboundBody(
                data: $0.data, compressedSize: $0.compressedSize))
        })
        for partial in partials {
            log(.event, "Holding \(partial.data.count) of \(partial.compressedSize) bytes of \(partial.mid) — will ask to resume")
        }

        let engine = B2FSessionEngine(config: .init(
            myCallsign: myCallsign,
            password: password,
            sid: sid ?? .axterm(version: Self.appVersion),
            role: role,
            outbound: prepared,
            partialInbound: partialInbound))
        self.engine = engine
        self.transport = transport

        transport.onReceive = { [weak self] data in
            self?.logWire(.received, data)
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
        statusText = role == .answering
            ? "Answering \(gatewayName)…"
            : "Connecting to \(gatewayName)…"
        progress = WinlinkExchangeProgress(kind: .connecting, startedAt: Date())
        do {
            try await transport.open()
        } catch {
            transport.onClose = nil
            return await finish(failure: "connect failed: \(describeTransportError(error))",
                                gatewayName: gatewayName, transportName: transportName)
        }

        phase = .exchanging
        // Answering carries no CMS sign-in: there is no account behind a
        // P2P peer to authenticate against.
        statusText = role == .answering
            ? "Exchanging with \(gatewayName)…"
            : "Signing in to \(gatewayName)…"
        progress = WinlinkExchangeProgress(kind: .handshake, startedAt: Date())

        let summary = await withCheckedContinuation { (continuation: CheckedContinuation<WinlinkExchangeSummary, Never>) in
            self.completion = continuation
            self.dispatch(.connected)
        }

        return await finish(summary: summary, gatewayName: gatewayName, transportName: transportName)
    }

    /// Dismisses a finished exchange's persistent result banner.
    func clearResult() {
        guard !isRunning else { return }
        phase = .idle
        statusText = ""
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
            logWire(.sent, data)
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
            log(.event, offset > 0
                ? "Gateway accepted \(mid) (resuming at byte \(offset))"
                : "Gateway accepted \(mid)")
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
            log(.event, "Gateway declined \(mid) — it usually means the CMS already has this message")
            Task { [worker] in
                try? await worker.markFailed(mid: mid, error: "declined by the gateway (FS N) — usually the CMS already received this message on an earlier attempt")
            }

        case .outboundDeferred(let mid):
            Task { [worker] in
                try? await worker.markDeferred(mid: mid)
            }

        case .messageFullyReceived(let message, let compressedSize):
            log(.event, "Received \(message.mid) \u{201C}\(message.subject)\u{201D} (\(compressedSize) bytes compressed)")
            statusText = "Received \(message.mid)"
            // The inquiry server's LIST reply doubles as the catalog
            // index — ingest it so the Catalog browser fills without the
            // (key-gated) web service.
            let catalogItems = WinlinkCatalogListReply.parse(message)
            if let catalogItems {
                log(.event, "Catalog index received \u{2014} \(catalogItems.count) products cached")
            }
            Task { [worker] in
                try? await worker.saveInbound(message)
                if let catalogItems {
                    try? await worker.replaceCatalogCache(catalogItems)
                }
            }

        case .receiveProgress(let mid, let bytes, let total, let resumedFrom):
            statusText = "Receiving \(mid)…"
            if progress?.kind == .receiving, progress?.mid == mid {
                progress?.bytesDone = bytes
                progress?.bytesTotal = total
                progress?.baselineBytes = resumedFrom
            } else {
                progress = WinlinkExchangeProgress(
                    kind: .receiving, mid: mid, bytesDone: bytes, bytesTotal: total,
                    baselineBytes: resumedFrom, startedAt: Date())
            }

        case .savePartialBody(let mid, let compressedSize, let data):
            log(.event, "Keeping \(data.count) of \(compressedSize) bytes of \(mid) — the next exchange will resume there")
            Task { [worker] in
                try? await worker.savePartialBody(mid: mid, compressedSize: compressedSize, data: data)
            }

        case .discardPartialBody(let mid):
            Task { [worker] in
                try? await worker.deletePartialBody(mid: mid)
            }

        case .captureCorruptBody(let mid, let resumedFrom, let declaredSize, let data):
            if let url = Self.writeCorruptBody(
                mid: mid, resumedFrom: resumedFrom, declaredSize: declaredSize, data: data) {
                log(.event, "Saved the undecodable body to \(url.path) — "
                    + "\(data.count) bytes, \(resumedFrom) of them resumed. "
                    + "Attach this file to a bug report; it is the only copy.")
            } else {
                // Silence here would look identical to "no failure happened".
                log(.event, "Could not save the undecodable body for \(mid) "
                    + "(\(data.count) bytes) — check that AXTerm can write to "
                    + "your Downloads folder.")
            }

        case .requestDisconnect:
            transport?.close()

        case .complete(let summary):
            log(.event, "Exchange complete — sent \(summary.sentMIDs.count), received \(summary.receivedMIDs.count)")
            resolve(with: summary)

        case .fail(let reason):
            log(.event, "Failed: \(reason)")
            var summary = engineSummaryForFailure(reason: reason)
            summary.failureReason = reason
            resolve(with: summary)
        }
    }

    /// Writes an undecodable compressed body to `~/Downloads/AXTerm
    /// Diagnostics/` so it can be analysed without waiting for the failure
    /// to recur — which, at 25 B/s on a capped session, means several
    /// attempts across many minutes.
    ///
    /// Downloads rather than Application Support: AXTerm is sandboxed, so
    /// Application Support redirects into
    /// `~/Library/Containers/com.rosswardrup.AXTerm/Data/…`, where nobody
    /// will find a file they have been asked to attach to a bug report.
    /// `com.apple.security.files.downloads.read-write` is already in the
    /// entitlements and puts the file somewhere real.
    ///
    /// The filename carries the resume offset because that is the single
    /// most useful fact about the file: it says exactly where the saved
    /// prefix ends and this session's bytes begin, so the two halves can be
    /// checked independently.
    nonisolated static func writeCorruptBody(
        mid: String, resumedFrom: Int, declaredSize: Int, data: Data
    ) -> URL? {
        guard let downloads = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let directory = downloads
            .appendingPathComponent("AXTerm Diagnostics", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        // Keep the MID filename-safe; MIDs are alphanumeric in practice but
        // nothing enforces it on the wire.
        let safeMID = mid.map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce(into: "") { $0.append($1) }
        let url = directory.appendingPathComponent(
            "\(safeMID)-\(stamp)-resumed\(resumedFrom)-of\(declaredSize).b2fbody")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// A failed session still moved bytes, and the session log is the only
    /// record of how many. Starting from a blank summary reported every
    /// interrupted transfer as zero — which made the Stations list's
    /// measured throughput collapse to 0 B/s for exactly the gateways that
    /// had done the most work.
    private func engineSummaryForFailure(reason: String) -> WinlinkExchangeSummary {
        var summary = engine?.currentSummary ?? WinlinkExchangeSummary()
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
        let summary = engineSummaryForFailure(reason: reason)
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
        //
        // A failed session's `sentMIDs` are *submitted*, not confirmed:
        // the body reached the transport but nothing says the CMS
        // committed it. Those requeue and the gateway declines the
        // duplicate by MID, which is the cheap direction to be wrong in.
        // (The byte counts on a failed summary are still real and are
        // kept — they are what the Stations list measures.)
        if summary.succeeded {
            for mid in summary.sentMIDs {
                try? await worker.markSent(mid: mid)
            }
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
            errorText: summary.failureReason,
            frequencyHz: sessionFrequencyHz,
            obsLatitude: observedLocation?.latitude,
            obsLongitude: observedLocation?.longitude,
            obsGrid: observedLocation?.gridSquare,
            obsSource: observedLocation?.source.rawValue)
        try? await worker.appendSessionLog(log)
        observationTask?.cancel()
        observationTask = nil

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

    // MARK: - Transcript

    /// Records a station-level event in the exchange transcript — used
    /// for things that happen outside a session, such as an inbound call
    /// that was declined. Without this a missed call leaves no trace at
    /// all, which is indistinguishable from a broken receiver.
    func note(_ text: String) {
        log(.event, text)
    }

    private func log(_ direction: WinlinkTranscriptEntry.Direction, _ text: String) {
        transcript.append(WinlinkTranscriptEntry(direction: direction, text: text))
        if transcript.count > Self.transcriptLimit {
            transcript.removeFirst(transcript.count - Self.transcriptLimit)
        }

        // Keep the toolbar status current during line-mode phases: while no
        // byte-level transfer is active, the label mirrors the latest gateway
        // line so "Signing in…" never sits stale through the conversation.
        if isRunning, direction == .received, (progress?.bytesTotal ?? 0) == 0 {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("‹") {
                statusText = trimmed
            }
        }
    }

    private func logWire(_ direction: WinlinkTranscriptEntry.Direction, _ data: Data) {
        for line in WinlinkTranscriptEntry.describeWireChunk(data) {
            log(direction, line)
        }
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}
