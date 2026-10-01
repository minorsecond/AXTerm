//
//  TransferPolicies.swift
//  AXTerm
//
//  The decisions behind packet file transfers, kept apart from the code that
//  acts on them so each can be tested without a radio, a window or a clock:
//  which protocol actually sends, whether an offer is taken, refused or put
//  to the operator, when a quiet transfer is given up on, and when the
//  operator hears about it through a notification.
//

import Foundation

// MARK: - Which protocol sends

/// How a transfer the operator asked for is carried.
nonisolated enum TransferSendRoute: Equatable, Sendable {
    /// AXTerm's own protocol, over the session or UI frames.
    case axdp
    /// YAPP over the connected session's I-frame stream.
    case yapp
    /// Nothing in this build can send it. Carries the reason to show.
    case unavailable(String)

    /// The route for a protocol. The operator's choice is what goes on the
    /// air: a protocol with no sender here is refused, never quietly swapped
    /// for another one.
    static func route(for type: TransferProtocolType) -> TransferSendRoute {
        switch type {
        case .axdp: return .axdp
        case .yapp: return .yapp
        case .sevenPlus, .rawBinary:
            return .unavailable("\(type.displayName) sending is not available in this version of AXTerm.")
        case .text:
            return .unavailable("Text can only be received from a session. Send the file by AXDP or YAPP.")
        }
    }

    /// What to say when a station has answered that it does not speak AXDP.
    /// YAPP is only suggested when it can actually be used, which means a
    /// connected session to that station.
    static func axdpUnsupportedMessage(destination: String, yappAvailable: Bool) -> String {
        if yappAvailable {
            return "Cannot send file: \(destination) does not support AXDP. Choose YAPP instead."
        }
        return "Cannot send file: \(destination) does not support AXDP. "
            + "Connect to \(destination) first to send it by YAPP."
    }
}

// MARK: - Offers

/// What happens to a file someone offers this station.
nonisolated enum TransferOfferDecision: Equatable, Sendable {
    case accept(reason: String)
    case decline(reason: String)
    /// Put it to the operator.
    case ask
}

/// Allow list, deny list and size cap, applied the same way wherever the
/// operator happens to be in the app.
nonisolated struct TransferOfferPolicy: Equatable, Sendable {
    var allowed: [String]
    var denied: [String]
    /// Offers larger than this are refused. Zero or less means no cap.
    var maxBytes: Int

    /// About two and a half hours of a clean 1200 baud channel. Received
    /// files are held in memory until they are complete, and a transfer that
    /// long holds the frequency against everyone else on it.
    static let defaultMaxBytes = 1_048_576

    /// The deny list wins over everything, then the cap, then the allow list.
    /// The cap applies to trusted stations too: it exists for the channel and
    /// for this device's memory, and neither cares who is sending.
    func decide(callsign: String, fileSize: Int) -> TransferOfferDecision {
        let call = CallsignValidator.normalize(callsign)
        if denied.contains(where: { CallsignValidator.normalize($0) == call }) {
            return .decline(reason: "\(call) is on your deny list")
        }
        if maxBytes > 0, fileSize > maxBytes {
            return .decline(reason: "\(ByteCount.string(fileSize)) is over the "
                            + "\(ByteCount.string(maxBytes)) limit for incoming files")
        }
        if allowed.contains(where: { CallsignValidator.normalize($0) == call }) {
            return .accept(reason: "\(call) is on your allow list")
        }
        return .ask
    }
}

// MARK: - Airtime

/// How long a transfer would hold the channel, from a rate this station has
/// actually measured. There is no guessed default: a number made up from a
/// nominal baud rate reads as a promise, and the prompt says nothing instead.
nonisolated enum TransferAirtimeEstimate {
    static func seconds(bytes: Int, bytesPerSecond: Double?) -> TimeInterval? {
        guard let bytesPerSecond, bytesPerSecond > 0, bytes >= 0 else { return nil }
        return Double(bytes) / bytesPerSecond
    }

    /// "under a minute", "about 12 minutes", "about 2 hours 5 minutes".
    static func describe(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "under a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        let rest = minutes % 60
        let hourText = "\(hours) hour\(hours == 1 ? "" : "s")"
        return rest == 0 ? "about \(hourText)" : "about \(hourText) \(rest) minute\(rest == 1 ? "" : "s")"
    }
}

// MARK: - Giving up on a quiet transfer

/// How long each kind of wait may last before a transfer is failed. A
/// transfer that nobody is answering must end with a reason rather than sit
/// "Sending" until the app quits.
nonisolated struct TransferTimeouts: Equatable, Sendable {
    /// Sender waiting for the other operator to accept.
    var awaitingAcceptance: TimeInterval = 600
    /// An offer waiting on this operator. Shorter than the sender's wait, so
    /// this side never accepts a transfer the sender has already given up on.
    var offerExpiry: TimeInterval = 540
    /// Sender with chunks to send and none leaving.
    var outboundStall: TimeInterval = 300
    /// Sender asking "do you have it all?" with no answer.
    var awaitingCompletion: TimeInterval = 180
    /// Receiver hearing nothing. Long, because the sender may have paused.
    var inboundStall: TimeInterval = 600

    static let standard = TransferTimeouts()
}

nonisolated enum TransferWatchdog {
    /// The reason to fail a transfer with, or nil to leave it alone.
    ///
    /// `idle` is the time since anything happened on this transfer. Paused
    /// and finished transfers are never timed out.
    static func verdict(status: BulkTransferStatus, direction: TransferDirection,
                        idle: TimeInterval, peer: String,
                        timeouts: TransferTimeouts = .standard) -> String? {
        switch (status, direction) {
        case (.awaitingAcceptance, _):
            return idle >= timeouts.awaitingAcceptance
                ? "\(peer) did not answer the offer within \(minutes(timeouts.awaitingAcceptance))."
                : nil
        case (.pending, .inbound):
            return idle >= timeouts.offerExpiry
                ? "The offer from \(peer) expired before it was answered."
                : nil
        case (.pending, .outbound), (.sending, .outbound):
            return idle >= timeouts.outboundStall
                ? "Nothing could be sent to \(peer) for \(minutes(timeouts.outboundStall))."
                : nil
        case (.awaitingCompletion, .outbound):
            return idle >= timeouts.awaitingCompletion
                ? "\(peer) stopped answering before confirming the file arrived."
                : nil
        case (.sending, .inbound), (.awaitingCompletion, .inbound):
            return idle >= timeouts.inboundStall
                ? "Nothing arrived from \(peer) for \(minutes(timeouts.inboundStall))."
                : nil
        case (.paused, _), (.completed, _), (.cancelled, _), (.failed, _):
            return nil
        }
    }

    private static func minutes(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds)) seconds" }
        let whole = Int((seconds / 60).rounded())
        return "\(whole) minute\(whole == 1 ? "" : "s")"
    }
}

// MARK: - Link loss

nonisolated enum TransferLinkLoss {
    /// The reason a transfer fails with when its AX.25 session goes away.
    /// `timedOut` is the session ending in error: the far station stopped
    /// answering and the link retries ran out.
    static func reason(peer: String, timedOut: Bool) -> String {
        timedOut
            ? "The link to \(peer) was lost: it stopped answering."
            : "The link to \(peer) closed before the transfer finished."
    }
}

// MARK: - Spotting an incoming YAPP transfer

nonisolated enum YAPPReceiveDetector {
    /// Whether a packet delivered on a terminal session starts a YAPP
    /// download. Only the exact SI packet counts, and only when nothing else
    /// is being transferred with that station: text never holds ENQ, and a
    /// second transfer on one session would interleave two byte streams.
    static func shouldStart(packet: Data, activeTransfersWithPeer: Int) -> Bool {
        activeTransfersWithPeer == 0 && YAPPProtocol.isSendInitPacket(packet)
    }
}

// MARK: - Notifications

/// Things about a transfer worth telling an operator who is not looking.
nonisolated enum TransferNotificationEvent: Equatable, Sendable {
    case offer(from: String, fileName: String, fileSize: Int)
    case completed(fileName: String, peer: String, direction: TransferDirection)
    case failed(fileName: String, peer: String, reason: String)
    case canceledByPeer(fileName: String, peer: String)
}

nonisolated enum TransferNotificationPolicy {
    /// An offer is only worth a notification when the app is in the
    /// background: in front, the prompt is already on screen. Results follow
    /// the operator's "only when inactive" setting like every other alert.
    static func shouldNotify(_ event: TransferNotificationEvent, enabled: Bool,
                             onlyWhenInactive: Bool, isFrontmost: Bool) -> Bool {
        guard enabled else { return false }
        switch event {
        case .offer:
            return !isFrontmost
        case .completed, .failed, .canceledByPeer:
            return !(onlyWhenInactive && isFrontmost)
        }
    }

    struct Content: Equatable, Sendable {
        let title: String
        let body: String
    }

    static func content(for event: TransferNotificationEvent) -> Content {
        switch event {
        case .offer(let from, let fileName, let fileSize):
            return Content(title: "\(from) wants to send you a file",
                           body: "\(fileName) (\(ByteCount.string(fileSize))). Open AXTerm to accept or decline.")
        case .completed(let fileName, let peer, let direction):
            return direction == .inbound
                ? Content(title: "File received from \(peer)",
                          body: "\(fileName) is in \(ReceivedFileStore.folderName).")
                : Content(title: "File sent to \(peer)", body: "\(fileName) arrived.")
        case .failed(let fileName, let peer, let reason):
            return Content(title: "Transfer with \(peer) failed", body: "\(fileName): \(reason)")
        case .canceledByPeer(let fileName, let peer):
            return Content(title: "\(peer) canceled a transfer", body: fileName)
        }
    }
}
