//
//  TalkRelay.swift
//  AXTerm
//
//  A caller at the node or the mailbox talking with the operator
//  (`TALK`, operator 2026-10-12).
//

import Combine
import Foundation

/// Watches a talking caller's bytes for `/EX` or `/EXIT` alone on a line,
/// typed or sent as AXDP chat. It only watches: the bytes still go to the
/// operator's terminal as they are.
nonisolated struct TalkExit {
    private var axdp = AXDPStreamReassembler()
    private var line = Data()

    /// True when the caller has asked to leave.
    mutating func feed(_ data: Data) -> Bool {
        var leaving = false
        let (messages, text) = axdp.split(data)
        for message in messages where message.type == .chat {
            if let payload = message.payload, Self.isExit(payload) { leaving = true }
        }
        for byte in text {
            if byte == 0x0D || byte == 0x0A {
                if Self.isExit(line) { leaving = true }
                line.removeAll()
            } else if line.count < 64 {
                line.append(byte)
            }
        }
        return leaving
    }

    private static func isExit(_ bytes: Data) -> Bool {
        let word = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces).uppercased()
        return word == "/EX" || word == "/EXIT"
    }
}

/// The operator's side of TALK, for the station's UI: callers waiting to
/// talk, and the chat under way. The station (`SessionCoordinator`) fills
/// it and does what the operator chooses.
@MainActor
final class TalkRouter: ObservableObject {
    /// Where the caller asked from, and goes back to.
    enum Door: Equatable, Sendable {
        case node
        case mailbox
    }

    /// A caller waiting for the operator.
    struct Page: Identifiable, Equatable {
        let id = UUID()
        let caller: String
        let door: Door
        /// The caller's link, as the door names it.
        let hostKey: String
        let at: Date
    }

    /// The chat under way, on the caller's own link.
    struct Chat: Equatable {
        let caller: String
        let door: Door
        let session: AX25Session

        static func == (a: Chat, b: Chat) -> Bool {
            a.caller == b.caller && a.door == b.door && a.session === b.session
        }
    }

    @Published var pages: [Page] = []
    @Published var chat: Chat?

    var onAnswer: ((Page) -> Void)?
    var onDecline: ((Page) -> Void)?
    var onEnd: (() -> Void)?

    /// The operator takes the call.
    func answer(_ page: Page) { onAnswer?(page) }
    /// Not now: the caller is told nobody is at the station.
    func decline(_ page: Page) { onDecline?(page) }
    /// The operator ends the chat; the caller goes back where they were.
    func endChat() { onEnd?() }
}

/// The chat under way, as the station holds it: the caller's link, claimed
/// for the operator's terminal, and what to give back to the door.
struct TalkState {
    let claim: SessionDeliveryClaim
    let session: AX25Session
    let door: TalkRouter.Door
    /// The caller's owner sign-in at the node, kept for the way back.
    let owner: OwnerConsole?
}

/// The words the operator's banner uses.
nonisolated enum TalkBannerText {
    static func page(caller: String, door: TalkRouter.Door) -> String {
        "\(caller) wants to talk (\(place(door)))"
    }

    static func chat(caller: String) -> String {
        "Talking with \(caller). They type /EX to go back."
    }

    static func place(_ door: TalkRouter.Door) -> String {
        door == .node ? "at the node" : "at the mailbox"
    }
}
