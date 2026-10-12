//
//  SessionCoordinator+Talk.swift
//  AXTerm
//
//  TALK: a caller at the node or the mailbox talks with the operator on
//  their own link, without leaving (operator, 2026-10-12). The station
//  pages the operator; answered, it takes the link from the door and hands
//  its bytes to the operator's terminal; `/EX`, the operator ending the
//  chat, or the link going down takes it back.
//

import Foundation

extension SessionCoordinator {

    /// Points the talk router's buttons at the station. Called once, from
    /// `init`.
    func wireTalk() {
        talkRouter.onAnswer = { [weak self] in self?.answerTalk($0) }
        talkRouter.onDecline = { [weak self] in self?.declineTalk($0) }
        talkRouter.onEnd = { [weak self] in self?.endTalk(operatorLeft: true) }
    }

    /// A caller asked to talk: page the operator, and give up after
    /// `talkPageTimeout`.
    func requestTalk(hostKey: String, caller: String, door: TalkRouter.Door) {
        guard !talkRouter.pages.contains(where: { $0.hostKey == hostKey }) else { return }
        let page = TalkRouter.Page(caller: caller, door: door, hostKey: hostKey, at: Date())
        talkRouter.pages.append(page)
        postTalkPage?(page)
        packetEngine?.appendSystemNotification("\(caller) wants to talk (\(door == .node ? "at the node" : "at the mailbox")).")
        let timeout = talkPageTimeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.talkRouter.pages.contains(where: { $0.id == page.id }) else { return }
            self.declineTalk(page)
        }
    }

    /// Nobody took the call: the caller is back where they asked from.
    func declineTalk(_ page: TalkRouter.Page) {
        guard talkRouter.pages.contains(where: { $0.id == page.id }) else { return }
        talkRouter.pages.removeAll { $0.id == page.id }
        clearTalkPage?(page)
        switch page.door {
        case .node: netRomNodeHost.talkDeclined(key: page.hostKey)
        case .mailbox: nodeMailbox?.talkDeclined()
        }
    }

    /// The caller left while waiting.
    func dropTalkPages(forHostKey hostKey: String) {
        for page in talkRouter.pages where page.hostKey == hostKey { clearTalkPage?(page) }
        talkRouter.pages.removeAll { $0.hostKey == hostKey }
    }

    /// The operator took the call: the link leaves its door for the
    /// operator's terminal.
    func answerTalk(_ page: TalkRouter.Page) {
        guard talkRouter.pages.contains(where: { $0.id == page.id }) else { return }
        guard talkState == nil else { return declineTalk(page) }
        talkRouter.pages.removeAll { $0.id == page.id }
        clearTalkPage?(page)
        switch page.door {
        case .node:
            guard let (key, claim) = nodeL2Claims.first(where: { "\($0.key)" == page.hostKey }),
                  let session = sessionManager.sessions[key], session.state == .connected else { return }
            sessionManager.releaseDelivery(claim)
            nodeL2Claims.removeValue(forKey: key)
            let owner = netRomNodeHost.yieldForTalk(key: page.hostKey)
            startTalk(on: session, caller: page.caller, door: .node, owner: owner)
        case .mailbox:
            guard let session = nodeMailbox?.lendForTalk(), "\(session.key)" == page.hostKey else { return }
            startTalk(on: session, caller: page.caller, door: .mailbox, owner: nil)
        }
    }

    private func startTalk(on session: AX25Session, caller: String, door: TalkRouter.Door, owner: OwnerConsole?) {
        var exit = TalkExit()
        let link = "ax25:\(session.key)"
        guard let claim = sessionManager.claimDelivery(
            for: session.key,
            handler: { [weak self] session, data in
                guard let self else { return }
                // Heard from the caller: an owner's changes stay made.
                self.nodeMailbox?.remoteControl.heard(link)
                self.sessionManager.deliverUnclaimed(data, on: session)
                if exit.feed(data) { self.endTalk(operatorLeft: false) }
            },
            stateHandler: { [weak self] _, _, newState in
                guard newState == .disconnected || newState == .error else { return }
                self?.talkLinkEnded(failed: newState == .error)
            }
        ) else { return }
        talkState = TalkState(claim: claim, session: session, door: door, owner: owner)
        writeToTalker(["*** You are talking with the operator. /EX takes you back."], on: session)
        talkRouter.chat = TalkRouter.Chat(caller: caller, door: door, session: session)
    }

    /// The chat is over: `/EX`, or the operator ended it. The caller goes
    /// back to the door they asked from.
    func endTalk(operatorLeft: Bool) {
        guard let state = talkState else { return }
        talkState = nil
        talkRouter.chat = nil
        sessionManager.releaseDelivery(state.claim)
        if operatorLeft { writeToTalker(["*** The operator left the chat."], on: state.session) }
        switch state.door {
        case .node: attachNodeCaller(state.session, owner: state.owner, returning: true)
        case .mailbox: nodeMailbox?.returnFromTalk()
        }
    }

    /// The caller's link went down mid-chat. A failed link is the owner's
    /// control link failing, so the fail-safe runs.
    private func talkLinkEnded(failed: Bool) {
        guard let state = talkState else { return }
        talkState = nil
        talkRouter.chat = nil
        switch state.door {
        case .node: nodeMailbox?.remoteControl.linkEnded("ax25:\(state.session.key)", failed: failed)
        case .mailbox: nodeMailbox?.lentLinkEnded(failed: failed)
        }
    }

    private func writeToTalker(_ lines: [String], on session: AX25Session) {
        let data = Data(lines.map { $0 + "\r" }.joined().utf8)
        let frames = sessionManager.sendData(data, to: session.remoteAddress, path: session.path, radio: session.radio,
                                             from: session.localAddress, pid: 0xF0,
                                             displayInfo: "Talk (\(data.count) bytes)")
        for frame in frames { _ = sendFrame(frame) }
    }
}
