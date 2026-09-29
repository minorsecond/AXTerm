//
//  B2FResumeTests.swift
//  AXTermTests
//
//  B2F checkpoint/resume for interrupted downloads: when a session dies
//  mid-body the engine emits the received prefix for persistence, and the
//  next session answers the matching proposal with `FS !offset`, stitches
//  the continuation onto the prefix, and lets the LZHUF CRC arbitrate.
//
//  Motivating failure (2026-08-23): a ~43 KB catalog download from W0ARP-10
//  died at ~24 KB when the gateway closed the link; without resume, every
//  retry restarts from zero on a 23 B/s channel.
//

import XCTest
@testable import AXTerm

final class B2FResumeTests: XCTestCase {

    // MARK: - Harness (mirrors B2FSessionEngineTests)

    private final class Harness {
        let engine: B2FSessionEngine
        var actions = [B2FSessionEngine.Action]()
        var sentData = Data()

        init(config: B2FSessionEngine.Config) {
            engine = B2FSessionEngine(config: config)
        }

        func fire(_ event: B2FSessionEngine.Event) {
            let newActions = engine.handle(event)
            actions.append(contentsOf: newActions)
            for action in newActions {
                if case .send(let data) = action { sentData.append(data) }
            }
        }

        func receive(_ text: String) { fire(.bytesReceived(Data(text.utf8))) }
        func receive(_ data: Data) { fire(.bytesReceived(data)) }

        var sentText: String { String(data: sentData, encoding: .isoLatin1) ?? "" }

        var savedPartial: (mid: String, compressedSize: Int, data: Data)? {
            for action in actions {
                if case .savePartialBody(let mid, let size, let data) = action {
                    return (mid, size, data)
                }
            }
            return nil
        }

        var discardedMIDs: [String] {
            actions.compactMap {
                if case .discardPartialBody(let mid) = $0 { return mid }
                return nil
            }
        }

        var failureReason: String? {
            for action in actions {
                if case .fail(let reason) = action { return reason }
            }
            return nil
        }

        var receivedMIDs: [String] {
            actions.compactMap {
                if case .messageFullyReceived(let message, _) = $0 { return message.mid }
                return nil
            }
        }
    }

    private let banner = "W0ARP-10 Gateway\r\n[WL2K-5.0-B2FWIHJM$]\r\n;PQ: 23753528\r\nCMS >\r\n"

    private func makeMessage(mid: String) -> WinlinkB2Message {
        WinlinkB2Message(
            mid: mid,
            date: WinlinkB2Message.dateFormatter.date(from: "2026/08/23 12:00")!,
            type: .privateMessage,
            from: "SERVICE",
            to: ["K0EPI"],
            cc: [],
            subject: "Catalog",
            mbo: "SERVICE",
            body: Data(String(repeating: "The quick brown fox jumps over the lazy dog. \r\n", count: 60).utf8),
            attachments: []
        )
    }

    private func compressed(_ message: WinlinkB2Message) throws -> Data {
        LZHUF.encodeB2F(try message.encode())
    }

    private func proposalBlock(for message: WinlinkB2Message) throws -> String {
        let encoded = try message.encode()
        let proposal = B2FProposal.Proposal(
            kind: .encapsulatedMessage,
            mid: message.mid,
            uncompressedSize: encoded.count,
            compressedSize: LZHUF.encodeB2F(encoded).count)
        return B2FProposal.renderBlock([proposal]).replacingOccurrences(of: "\r", with: "\r\n")
    }

    /// A connected harness that has finished the handshake (empty outbox →
    /// FF already sent) and holds `partials` from earlier sessions.
    private func handshakenHarness(
        partials: [String: B2FSessionEngine.PartialInboundBody] = [:]
    ) -> Harness {
        let harness = Harness(config: .init(
            myCallsign: "K0EPI", password: "SECRET", partialInbound: partials))
        harness.fire(.connected)
        harness.receive(banner)
        return harness
    }

    // MARK: - Saving a partial when the session dies mid-body

    func testLinkLossMidBodyEmitsSavePartial() throws {
        let message = makeMessage(mid: "CATALOG00001")
        let body = try compressed(message)
        let harness = handshakenHarness()
        harness.receive(try proposalBlock(for: message))
        XCTAssertTrue(harness.sentText.contains("FS Y\r"), harness.sentText)

        // Header plus the first full 125-byte STX block, then silence.
        let framed = FBBBlockCodec.encode(title: "t", offset: 0, payload: body)
        let headerLength = 2 + Int(framed[1])          // SOH + len byte + header body
        let firstBlockEnd = headerLength + 2 + 125     // STX + len + data
        harness.receive(Data(framed.prefix(firstBlockEnd)))
        harness.fire(.linkDisconnected)

        let saved = try XCTUnwrap(harness.savedPartial)
        XCTAssertEqual(saved.mid, "CATALOG00001")
        XCTAssertEqual(saved.compressedSize, body.count)
        XCTAssertEqual(saved.data, body.prefix(125), "exactly the payload bytes that arrived")
        XCTAssertNotNil(harness.failureReason)
    }

    func testBinaryTimeoutMidBodyEmitsSavePartial() throws {
        let message = makeMessage(mid: "CATALOG00002")
        let body = try compressed(message)
        let harness = handshakenHarness()
        harness.receive(try proposalBlock(for: message))

        let framed = FBBBlockCodec.encode(title: "t", offset: 0, payload: body)
        let headerLength = 2 + Int(framed[1])
        harness.receive(Data(framed.prefix(headerLength + 2 + 125)))
        harness.fire(.timerFired(.binary))

        XCTAssertEqual(harness.savedPartial?.data, body.prefix(125))
    }

    func testAbortMidBodyEmitsSavePartialAndDisconnect() throws {
        let message = makeMessage(mid: "CATALOG00003")
        let body = try compressed(message)
        let harness = handshakenHarness()
        harness.receive(try proposalBlock(for: message))

        let framed = FBBBlockCodec.encode(title: "t", offset: 0, payload: body)
        let headerLength = 2 + Int(framed[1])
        harness.receive(Data(framed.prefix(headerLength + 2 + 125)))
        harness.fire(.abortRequested)

        XCTAssertEqual(harness.savedPartial?.data, body.prefix(125))
        XCTAssertTrue(harness.actions.contains(.requestDisconnect))
    }

    func testCorruptStreamIsNeverSavedAsAPartial() throws {
        let message = makeMessage(mid: "CATALOG00004")
        let body = try compressed(message)
        let harness = handshakenHarness()
        harness.receive(try proposalBlock(for: message))

        var framed = FBBBlockCodec.encode(title: "t", offset: 0, payload: body)
        framed[framed.count - 1] &+= 1  // break the EOT checksum
        harness.receive(framed)

        XCTAssertNil(harness.savedPartial, "checksum-failed bytes are suspect and must not be kept")
        XCTAssertNotNil(harness.failureReason)
    }

    /// A resumed stream that fails its checksum proves the *stored* prefix
    /// is bad. Leaving it in place makes every future exchange resume from
    /// the same poisoned bytes and fail at exactly the same offset — the
    /// download can never complete again.
    func testChecksumFailureOnAResumedStreamDiscardsThePoisonedPrefix() throws {
        let message = makeMessage(mid: "CATALOG00012")
        let body = try compressed(message)
        let offset = 137
        let harness = handshakenHarness(partials: [
            message.mid: .init(data: body.prefix(offset), compressedSize: body.count)
        ])
        harness.receive(try proposalBlock(for: message))

        var framed = FBBBlockCodec.encode(title: "t", offset: offset, payload: body)
        framed[framed.count - 1] &+= 1  // break the EOT checksum
        harness.receive(framed)

        XCTAssertNil(harness.savedPartial)
        XCTAssertTrue(harness.discardedMIDs.contains(message.mid),
                      "the prefix that produced a bad checksum must be dropped, "
                      + "or the next attempt repeats the same failure forever")
        XCTAssertNotNil(harness.failureReason)
    }

    /// A body that assembles but will not decode must be kept. The failure
    /// costs a full re-download to reproduce, and nothing in the numbers
    /// distinguishes a bad saved prefix from bad bytes received now — only
    /// the body itself does.
    func testUndecodableBodyIsCapturedWithItsResumeOffset() throws {
        let message = makeMessage(mid: "CATALOG00014")
        let body = try compressed(message)
        let offset = 137
        // A prefix that is the right length but the wrong bytes: the
        // stitched body assembles cleanly and fails CRC16. Its first six
        // bytes must be the genuine wire header — a resumed gateway
        // re-sends the header and the engine strips it by matching it
        // against these bytes; junk *after* the header is what a corrupt
        // store actually looks like.
        var bogusPrefix = Data(body.prefix(LZHUF.wireHeaderSize))
        bogusPrefix.append(Data(repeating: 0xAA, count: offset - LZHUF.wireHeaderSize))
        let harness = handshakenHarness(partials: [
            message.mid: .init(data: bogusPrefix, compressedSize: body.count)
        ])
        harness.receive(try proposalBlock(for: message))
        // encode() drops `offset` bytes itself — pass the whole body.
        harness.receive(FBBBlockCodec.encode(title: "t", offset: offset, payload: body))

        let captured = harness.actions.compactMap { action -> (String, Int, Int, Data)? in
            if case .captureCorruptBody(let mid, let resumedFrom, let declared, let data) = action {
                return (mid, resumedFrom, declared, data)
            }
            return nil
        }
        let capture = try XCTUnwrap(captured.first, "the undecodable body must be kept")
        XCTAssertEqual(capture.0, message.mid)
        XCTAssertEqual(capture.1, offset, "the resume boundary is what splits the suspects")
        XCTAssertEqual(capture.2, body.count)
        XCTAssertEqual(capture.3.count, body.count, "prefix plus continuation, verbatim")
        XCTAssertEqual(capture.3.prefix(offset), bogusPrefix)

        XCTAssertTrue(harness.discardedMIDs.contains(message.mid))
        let reason = try XCTUnwrap(harness.failureReason)
        XCTAssertTrue(reason.contains("saved prefix is the"), reason)
    }

    /// A CRC failure with no resume points at delivery, not at a stitch,
    /// and the message must say so rather than blaming a prefix that does
    /// not exist.
    func testDecodeFailureWithoutAResumeBlamesDeliveryNotAStitch() throws {
        let message = makeMessage(mid: "CATALOG00015")
        var body = try compressed(message)
        body[body.count / 2] ^= 0xFF  // corrupt a byte in the middle
        let harness = handshakenHarness()
        harness.receive(try proposalBlock(for: message))
        harness.receive(FBBBlockCodec.encode(title: "t", offset: 0, payload: body))

        let reason = try XCTUnwrap(harness.failureReason)
        XCTAssertTrue(reason.contains("nothing was resumed"), reason)
        XCTAssertFalse(harness.discardedMIDs.contains(message.mid),
                       "there was no stored prefix to discard")
    }

    /// The failure text has to say which case it is: a fresh transfer
    /// failing checksum is a delivery problem, a resumed one is a stitch
    /// problem, and they lead to different investigations.
    func testChecksumFailureNamesTheResumeAsTheSuspect() throws {
        let message = makeMessage(mid: "CATALOG00013")
        let body = try compressed(message)
        let offset = 137
        let harness = handshakenHarness(partials: [
            message.mid: .init(data: body.prefix(offset), compressedSize: body.count)
        ])
        harness.receive(try proposalBlock(for: message))
        var framed = FBBBlockCodec.encode(title: "t", offset: offset, payload: body)
        framed[framed.count - 1] &+= 1
        harness.receive(framed)

        let reason = try XCTUnwrap(harness.failureReason)
        XCTAssertTrue(reason.contains("\(offset) bytes"), reason)
        XCTAssertTrue(reason.contains(message.mid), reason)
    }

    func testNothingReceivedMeansNothingSaved() throws {
        let message = makeMessage(mid: "CATALOG00005")
        let harness = handshakenHarness()
        harness.receive(try proposalBlock(for: message))
        harness.fire(.linkDisconnected)
        XCTAssertNil(harness.savedPartial)
    }

    // MARK: - Resuming with a saved partial

    func testResumeAnswersWithOffsetAndStitchesTheContinuation() throws {
        let message = makeMessage(mid: "CATALOG00006")
        let body = try compressed(message)
        let offset = 137
        let harness = handshakenHarness(partials: [
            message.mid: .init(data: body.prefix(offset), compressedSize: body.count)
        ])

        harness.receive(try proposalBlock(for: message))
        XCTAssertTrue(harness.sentText.contains("FS !\(offset)\r"), harness.sentText)

        // A compliant gateway resumes exactly at the requested offset.
        harness.receive(FBBBlockCodec.encode(title: "t", offset: offset, payload: body))

        XCTAssertEqual(harness.receivedMIDs, [message.mid], "stitched body must decode")
        XCTAssertEqual(harness.discardedMIDs, [message.mid], "consumed partial is cleared")
        XCTAssertNil(harness.failureReason)
    }

    func testGatewayIgnoringResumeRestartsCleanly() throws {
        let message = makeMessage(mid: "CATALOG00007")
        let body = try compressed(message)
        let harness = handshakenHarness(partials: [
            message.mid: .init(data: body.prefix(100), compressedSize: body.count)
        ])

        harness.receive(try proposalBlock(for: message))
        XCTAssertTrue(harness.sentText.contains("FS !100\r"))

        // Gateway sends the whole body from offset 0 despite our request.
        harness.receive(FBBBlockCodec.encode(title: "t", offset: 0, payload: body))

        XCTAssertEqual(harness.receivedMIDs, [message.mid], "full restart must still decode")
        XCTAssertTrue(harness.discardedMIDs.contains(message.mid))
        XCTAssertNil(harness.failureReason)
    }

    func testSizeMismatchedPartialIsDiscardedAndAcceptedFresh() throws {
        let message = makeMessage(mid: "CATALOG00008")
        let body = try compressed(message)
        let harness = handshakenHarness(partials: [
            message.mid: .init(data: Data(repeating: 0xAA, count: 50), compressedSize: body.count + 999)
        ])

        harness.receive(try proposalBlock(for: message))
        XCTAssertTrue(harness.sentText.contains("FS Y\r"), "different encoding → no resume: \(harness.sentText)")
        XCTAssertTrue(harness.discardedMIDs.contains(message.mid))

        harness.receive(FBBBlockCodec.encode(title: "t", offset: 0, payload: body))
        XCTAssertEqual(harness.receivedMIDs, [message.mid])
    }

    func testGatewayResumingBeyondHeldBytesFailsWithoutStitching() throws {
        let message = makeMessage(mid: "CATALOG00009")
        let body = try compressed(message)
        let harness = handshakenHarness(partials: [
            message.mid: .init(data: body.prefix(100), compressedSize: body.count)
        ])

        harness.receive(try proposalBlock(for: message))
        // Broken gateway skips further than we hold — an unfillable gap.
        harness.receive(FBBBlockCodec.encode(title: "t", offset: 150, payload: body))

        XCTAssertNotNil(harness.failureReason)
        XCTAssertTrue(harness.receivedMIDs.isEmpty)
        XCTAssertNil(harness.savedPartial, "gap bytes must not be persisted")
    }

    func testCorruptStoredPrefixFailsDecodeAndDiscardsThePartial() throws {
        let message = makeMessage(mid: "CATALOG00010")
        let body = try compressed(message)
        let offset = 137
        let harness = handshakenHarness(partials: [
            message.mid: .init(data: Data(repeating: 0x55, count: offset), compressedSize: body.count)
        ])

        harness.receive(try proposalBlock(for: message))
        harness.receive(FBBBlockCodec.encode(title: "t", offset: offset, payload: body))

        XCTAssertNotNil(harness.failureReason, "stitched CRC must catch a bad prefix")
        XCTAssertTrue(harness.discardedMIDs.contains(message.mid), "bad prefix cleared for a clean restart")
        XCTAssertNil(harness.savedPartial)
    }

    func testResumeProgressCountsThePrefix() throws {
        let message = makeMessage(mid: "CATALOG00011")
        let body = try compressed(message)
        let offset = 137
        let harness = handshakenHarness(partials: [
            message.mid: .init(data: body.prefix(offset), compressedSize: body.count)
        ])
        harness.receive(try proposalBlock(for: message))

        let framed = FBBBlockCodec.encode(title: "t", offset: offset, payload: body)
        let headerLength = 2 + Int(framed[1])
        let firstBlock = min(125, body.count - offset + LZHUF.wireHeaderSize)
        harness.receive(Data(framed.prefix(headerLength + 2 + firstBlock)))

        let progress = harness.actions.compactMap { action -> (bytes: Int, resumedFrom: Int)? in
            if case .receiveProgress(_, let bytes, _, let resumedFrom) = action {
                return (bytes, resumedFrom)
            }
            return nil
        }
        // The first block carries the re-sent six-byte wire header, which
        // is stripped — only real stream bytes may move the bar.
        XCTAssertEqual(progress.last?.bytes, offset + firstBlock - LZHUF.wireHeaderSize,
                       "the bar resumes at the prefix, not at zero")
        XCTAssertEqual(progress.last?.resumedFrom, offset,
                       "the prefix is reported separately so rate and ETA can exclude it")
    }

    /// The rate must measure airtime, not the resumed prefix — counting the
    /// prefix made a 1200-baud link read as 1 KB/s and gave an ETA far
    /// shorter than the transfer could possibly finish in.
    func testRateExcludesTheResumedPrefix() {
        let started = Date(timeIntervalSinceReferenceDate: 0)
        let progress = WinlinkExchangeProgress(
            kind: .receiving, mid: "6KFOMF87WJ8T",
            bytesDone: 28_672, bytesTotal: 42_548,
            baselineBytes: 27_291, startedAt: started)
        let now = started.addingTimeInterval(28)

        XCTAssertEqual(progress.bytesPerSecond(now: now) ?? 0, 1381.0 / 28.0, accuracy: 0.01,
                       "only the 1381 bytes received this session count toward the rate")

        // (42548 - 28672) / (1381/28) ≈ 281 s, not the 13 s the old math gave.
        XCTAssertEqual(progress.estimatedSecondsRemaining(now: now) ?? 0, 281, accuracy: 2)
    }

    func testRateIsUnaffectedWhenNothingWasResumed() {
        let started = Date(timeIntervalSinceReferenceDate: 0)
        let progress = WinlinkExchangeProgress(
            kind: .receiving, mid: "PLAIN0000001",
            bytesDone: 3_000, bytesTotal: 9_000, startedAt: started)
        XCTAssertEqual(progress.bytesPerSecond(now: started.addingTimeInterval(100)) ?? 0,
                       30, accuracy: 0.001)
    }

    // MARK: - The re-sent wire header on resume
    //
    // Field capture 2026-08-24 (MID 6KFOMF87WJ8T, W0ARP-10): on every
    // `FS !offset` resume the gateway re-sends the six-byte LZHUF wire
    // header (CRC16 + uncompressed length) before continuing the stream at
    // the offset. The capture held that header verbatim at all four resume
    // seams (file offsets 0, 3870, 12433, 17313, 42003). Appending it
    // corrupts the stream AND inflates the saved byte count, so each
    // subsequent resume asks six bytes too far ahead and the gateway skips
    // six real bytes: four resumes injected 24 junk bytes and dropped 18
    // real ones, and no retry could ever converge.
    //
    // These tests simulate the gateway with a hand-built framer rather
    // than FBBBlockCodec.encode, so the simulation cannot share a bug with
    // the code under test — which is exactly how the original bug hid: the
    // old tests modeled a gateway that never re-sends the header.

    /// Frames a body the way the field capture shows the RMS does.
    /// `resendHeader` re-transmits `wire`'s first six bytes ahead of the
    /// stream when resuming; `false` models a sender that continues
    /// verbatim (our encoder's historical behavior) — the engine must
    /// stitch both correctly.
    private func gatewayFrame(
        offset: Int, wire: Data, resendHeader: Bool, title: String = "t"
    ) -> Data {
        var out = Data()
        let titleBytes = Array(title.utf8)
        let offsetBytes = Array(String(offset).utf8)
        out.append(0x01)  // SOH
        out.append(UInt8(titleBytes.count + offsetBytes.count + 2))
        out.append(contentsOf: titleBytes)
        out.append(0x00)
        out.append(contentsOf: offsetBytes)
        out.append(0x00)

        var stream = Data()
        if resendHeader && offset > 0 { stream.append(wire.prefix(6)) }
        stream.append(Data(wire.dropFirst(offset)))

        var checksum: UInt8 = 0
        var index = stream.startIndex
        while index < stream.endIndex {
            let end = stream.index(index, offsetBy: 125, limitedBy: stream.endIndex) ?? stream.endIndex
            let chunk = stream[index..<end]
            out.append(0x02)  // STX
            out.append(UInt8(chunk.count))
            out.append(contentsOf: chunk)
            for byte in chunk { checksum = checksum &+ byte }
            index = end
        }
        out.append(0x04)  // EOT
        out.append(UInt8(truncatingIfNeeded: 0 &- Int(checksum)))
        return out
    }

    /// SOH byte + length byte + header body, for slicing partial feeds.
    private func sohLength(offset: Int, title: String = "t") -> Int {
        2 + title.utf8.count + String(offset).utf8.count + 2
    }

    /// A body that LZHUF cannot shrink, so the compressed wire is long
    /// enough to interrupt at several block boundaries.
    private func incompressibleMessage(mid: String, byteCount: Int = 3_000) -> WinlinkB2Message {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var body = Data(capacity: byteCount)
        for _ in 0..<byteCount {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            body.append(UInt8(truncatingIfNeeded: state))
        }
        return WinlinkB2Message(
            mid: mid,
            date: WinlinkB2Message.dateFormatter.date(from: "2026/08/24 05:33")!,
            type: .privateMessage,
            from: "SERVICE",
            to: ["K0EPI"],
            cc: [],
            subject: "Catalog",
            mbo: "SERVICE",
            body: body,
            attachments: [])
    }

    func testResumedStreamStripsTheReSentWireHeader() throws {
        let message = incompressibleMessage(mid: "CATALOG00020")
        let wire = try compressed(message)
        let offset = 137
        let harness = handshakenHarness(partials: [
            message.mid: .init(data: wire.prefix(offset), compressedSize: wire.count)
        ])
        harness.receive(try proposalBlock(for: message))
        XCTAssertTrue(harness.sentText.contains("FS !\(offset)\r"), harness.sentText)

        harness.receive(gatewayFrame(offset: offset, wire: wire, resendHeader: true))

        XCTAssertNil(harness.failureReason)
        XCTAssertEqual(harness.receivedMIDs, [message.mid],
                       "the re-sent header must be stripped, not stitched into the stream")
    }

    /// The compounding failure from the field capture: every resume that
    /// appends the re-sent header saves six junk bytes, so the next
    /// `FS !offset` overshoots by six and the gateway skips six real bytes.
    /// Three sessions, two resumes — every saved prefix and every FS offset
    /// must stay byte-truthful, and the final stitch must decode.
    func testResumeChainKeepsOffsetsTruthfulAndCompletes() throws {
        let message = incompressibleMessage(mid: "CATALOG00021")
        let wire = try compressed(message)
        XCTAssertGreaterThan(wire.count, 500, "need room for two interruptions")

        // Session 1: from zero, two full 125-byte blocks arrive, link dies.
        let s1 = handshakenHarness()
        s1.receive(try proposalBlock(for: message))
        let frame1 = gatewayFrame(offset: 0, wire: wire, resendHeader: false)
        s1.receive(Data(frame1.prefix(sohLength(offset: 0) + 2 * 127)))
        s1.fire(.linkDisconnected)
        let saved1 = try XCTUnwrap(s1.savedPartial)
        XCTAssertEqual(saved1.data, wire.prefix(250))

        // Session 2: resumes at 250; the gateway re-sends the header, so
        // the first 125-byte block carries 6 header bytes + 119 stream
        // bytes. Link dies again.
        let s2 = handshakenHarness(partials: [
            message.mid: .init(data: saved1.data, compressedSize: wire.count)
        ])
        s2.receive(try proposalBlock(for: message))
        XCTAssertTrue(s2.sentText.contains("FS !250\r"), s2.sentText)
        let frame2 = gatewayFrame(offset: 250, wire: wire, resendHeader: true)
        s2.receive(Data(frame2.prefix(sohLength(offset: 250) + 127)))
        s2.fire(.linkDisconnected)
        let saved2 = try XCTUnwrap(s2.savedPartial)
        XCTAssertEqual(saved2.data.count, 369,
                       "250 held + 119 stream bytes — the 6 header bytes must not count")
        XCTAssertEqual(saved2.data, wire.prefix(369),
                       "the header must not be stitched in at the seam")

        // Session 3: resumes at the truthful 369 and completes.
        let s3 = handshakenHarness(partials: [
            message.mid: .init(data: saved2.data, compressedSize: wire.count)
        ])
        s3.receive(try proposalBlock(for: message))
        XCTAssertTrue(s3.sentText.contains("FS !369\r"), s3.sentText)
        s3.receive(gatewayFrame(offset: 369, wire: wire, resendHeader: true))

        XCTAssertNil(s3.failureReason)
        XCTAssertEqual(s3.receivedMIDs, [message.mid])
    }

    /// A sender that resumes without re-sending the header must still be
    /// stitched verbatim — the strip is keyed on the bytes actually
    /// matching the stored prefix, never assumed.
    func testResumeWithoutAReSentHeaderStillStitchesVerbatim() throws {
        let message = incompressibleMessage(mid: "CATALOG00022")
        let wire = try compressed(message)
        let offset = 137
        let harness = handshakenHarness(partials: [
            message.mid: .init(data: wire.prefix(offset), compressedSize: wire.count)
        ])
        harness.receive(try proposalBlock(for: message))
        harness.receive(gatewayFrame(offset: offset, wire: wire, resendHeader: false))

        XCTAssertNil(harness.failureReason)
        XCTAssertEqual(harness.receivedMIDs, [message.mid])
    }

    /// A re-sent header whose CRC differs from the stored prefix's means
    /// the gateway restarted from a different compression of the body —
    /// nothing we hold can be stitched to it. That must fail at the seam,
    /// six bytes in, not after downloading the whole body into a stream
    /// that was doomed from byte one.
    func testResumedHeaderFromADifferentCompressionFailsFastAndDiscards() throws {
        let message = incompressibleMessage(mid: "CATALOG00023")
        let wire = try compressed(message)
        let offset = 200
        var stale = Data(wire.prefix(offset))
        stale[0] ^= 0xFF  // same length field, different CRC — a different compression
        let harness = handshakenHarness(partials: [
            message.mid: .init(data: stale, compressedSize: wire.count)
        ])
        harness.receive(try proposalBlock(for: message))
        harness.receive(gatewayFrame(offset: offset, wire: wire, resendHeader: true))

        let reason = try XCTUnwrap(harness.failureReason)
        XCTAssertTrue(reason.contains("different compression"), reason)
        XCTAssertTrue(harness.discardedMIDs.contains(message.mid),
                      "the stale prefix can never stitch to this body again")
        XCTAssertNil(harness.savedPartial)
        XCTAssertTrue(harness.receivedMIDs.isEmpty)
        XCTAssertFalse(harness.actions.contains {
            if case .captureCorruptBody = $0 { return true }
            return false
        }, "detected at the seam — there is no assembled body worth keeping")
    }

    /// An interruption while the re-sent header itself is mid-flight leaves
    /// bytes that cannot be told apart from stream data. Saving them would
    /// poison the prefix; the stored prefix must survive untouched instead.
    func testInterruptionInsideTheReSentHeaderSavesNothingNew() throws {
        let message = incompressibleMessage(mid: "CATALOG00024")
        let wire = try compressed(message)
        let offset = 250
        let harness = handshakenHarness(partials: [
            message.mid: .init(data: wire.prefix(offset), compressedSize: wire.count)
        ])
        harness.receive(try proposalBlock(for: message))
        let frame = gatewayFrame(offset: offset, wire: wire, resendHeader: true)
        // SOH header, STX, length byte, then only 3 bytes of the re-sent header.
        harness.receive(Data(frame.prefix(sohLength(offset: offset) + 2 + 3)))
        harness.fire(.linkDisconnected)

        XCTAssertNil(harness.savedPartial,
                     "three ambiguous bytes must not be stitched onto the stored prefix")
        XCTAssertFalse(harness.discardedMIDs.contains(message.mid),
                       "the stored prefix is still good — the next session resumes from it")
    }

    /// The mirror image: when the gateway answers our proposal with
    /// `FS !offset`, our transmission must re-send the wire header before
    /// continuing at the offset, exactly as the gateway does for us.
    func testOutboundResumeReSendsTheWireHeader() throws {
        let message = incompressibleMessage(mid: "CATALOG00025")
        let encoded = try message.encode()
        let outbound = B2FSessionEngine.PreparedOutbound(
            message: message,
            compressed: LZHUF.encodeB2F(encoded),
            uncompressedSize: encoded.count)
        let harness = Harness(config: .init(
            myCallsign: "K0EPI", password: "SECRET", outbound: [outbound]))
        harness.fire(.connected)
        harness.receive(banner)
        harness.receive("FS !300\r\n")

        let framed = try XCTUnwrap(harness.actions.compactMap { action -> Data? in
            if case .send(let data) = action, data.first == 0x01 { return data }
            return nil
        }.first, "the accepted-from-offset body must be framed and sent")
        let parser = FBBBlockCodec.Parser()
        var payload: Data?
        var declaredOffset: Int?
        for event in parser.feed(framed) {
            if case .header(_, let offset) = event { declaredOffset = offset }
            if case .completed(let data) = event { payload = data }
        }
        XCTAssertEqual(declaredOffset, 300)
        let expected = Data(outbound.compressed.prefix(6))
            + Data(outbound.compressed.dropFirst(300))
        XCTAssertEqual(payload, expected,
                       "resumed outbound must re-send the six-byte wire header, "
                       + "then continue at the offset — the receiver strips it by match")
    }
}
