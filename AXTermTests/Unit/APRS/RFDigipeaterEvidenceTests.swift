import XCTest
import Combine
@testable import AXTerm

/// The AD1CT case, reproduced on a real modulated channel and driven through
/// AXTerm's own decoder.
///
/// A Direwolf with `DIGIPEAT` and no APRS application behind it is the most
/// common station on an APRS channel: it repeats WIDEn-N traffic with callsign
/// substitution and answers no query, ever. That combination is what made
/// "it hears me but won't answer" look like a defect.
///
/// The fixture is full AX.25 frames captured off `TestRig`'s `rfnet` profile —
/// each one AFSK-modulated by one modem and demodulated by another — so these
/// tests run `AX25.decodeFrame` over bytes that were genuinely on a channel,
/// then feed the result through the real `APRSPingTracker` subscription.
/// Regenerate with `TestRig/scripts/digi_capture.py`.
@MainActor
final class RFDigipeaterEvidenceTests: XCTestCase {

    struct Capture: Decodable {
        struct Heard: Decodable {
            let src: String
            let via: [String]
            let frameHex: String
            let infoAscii: String
            let isOurs: Bool
            let repeatedByDigi: Bool
            enum CodingKeys: String, CodingKey {
                case src, via
                case frameHex = "frame_hex"
                case infoAscii = "info_ascii"
                case isOurs = "is_ours"
                case repeatedByDigi = "repeated_by_digi"
            }
        }
        struct Probe: Decodable {
            let kind: String
            let sentVia: [String]
            let heard: [Heard]
            enum CodingKeys: String, CodingKey {
                case kind, heard
                case sentVia = "sent_via"
            }
        }
        let digipeater: String
        let askedAs: String
        let probes: [Probe]
        enum CodingKeys: String, CodingKey {
            case digipeater, probes
            case askedAs = "asked_as"
        }
    }

    private func capture() throws -> Capture {
        let url = try XCTUnwrap(
            Bundle(for: RFDigipeaterEvidenceTests.self)
                .url(forResource: "rf-digipeater", withExtension: "json"),
            "rf-digipeater.json is not in the test bundle")
        return try JSONDecoder().decode(Capture.self, from: Data(contentsOf: url))
    }

    private func probe(_ kind: String, in capture: Capture) throws -> Capture.Probe {
        try XCTUnwrap(capture.probes.first { $0.kind == kind }, "no probe \(kind)")
    }

    /// A captured frame, through AXTerm's real decoder, as a real `Packet`.
    private func packet(_ heard: Capture.Heard) throws -> Packet {
        let raw = try XCTUnwrap(Data(hexString: heard.frameHex),
                                "unreadable fixture hex")
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: raw),
                                    "AXTerm could not decode a frame that was on the air")
        return Packet(from: decoded.from, to: decoded.to, via: decoded.via,
                      frameType: decoded.frameType, control: decoded.control,
                      pid: decoded.pid, info: decoded.info, rawAx25: raw)
    }

    // MARK: - What the channel actually did

    /// Our own frame comes back with the digipeater's callsign substituted into
    /// the path and marked used — the H-bit that makes it evidence rather than
    /// a request.
    func testOurFrameComesBackWithTheDigipeaterMarkedUsed() async throws {
        let cap = try capture()
        let repeated = try XCTUnwrap(
            try probe("beacon-via-wide", in: cap).heard.first { $0.repeatedByDigi },
            "the digipeater did not repeat our beacon")

        let pkt = try packet(repeated)
        XCTAssertEqual(pkt.from?.display, cap.askedAs, "the source is still us")
        let used = pkt.via.filter(\.repeated).map(\.display)
        XCTAssertEqual(used, [cap.digipeater],
                       "expected \(cap.digipeater) marked repeated, got \(pkt.via)")
    }

    /// A frame sent direct has no path, so no digipeater can repeat it and no
    /// reception evidence is possible. This is why a silent *direct* ping says
    /// nothing about whether the station heard us.
    func testADirectFrameIsNeverDigipeated() async throws {
        let cap = try capture()
        let direct = try probe("beacon-direct", in: cap)
        XCTAssertTrue(direct.heard.allSatisfy { !$0.repeatedByDigi },
                      "a frame with no path was somehow repeated")
        for heard in direct.heard where heard.isOurs {
            XCTAssertTrue(try packet(heard).via.isEmpty)
        }
    }

    /// It repeats our query and still does not answer it. One probe, the whole
    /// confusion: reception proven, answer absent.
    func testItRepeatsOurQueryAndStillDoesNotAnswer() async throws {
        let cap = try capture()
        let viaWide = try probe("query-via-wide", in: cap)
        XCTAssertTrue(viaWide.heard.contains { $0.repeatedByDigi },
                      "it should have repeated the query")
        XCTAssertTrue(viaWide.heard.allSatisfy { $0.isOurs },
                      "every frame heard was our own; it answered nothing: "
                      + "\(viaWide.heard.filter { !$0.isOurs }.map(\.infoAscii))")
    }

    /// No query gets an answer — not position, not version, not trace.
    func testTheDigipeaterAnswersNoQueryAtAll() async throws {
        let cap = try capture()
        for kind in ["query-position", "query-version", "query-trace", "query-via-wide"] {
            let replies = try probe(kind, in: cap).heard.filter { !$0.isOurs }
            XCTAssertTrue(replies.isEmpty,
                          "\(kind) drew \(replies.map(\.infoAscii))")
        }
    }

    // MARK: - End to end through the tracker

    /// The whole evidence path on frames that were genuinely modulated:
    /// real bytes → `AX25.decodeFrame` → the tracker's live subscription →
    /// "it hears us but did not answer".
    func testTheEvidencePathTurnsARealDigipeatIntoProofOfReception() async throws {
        let cap = try capture()
        let repeated = try XCTUnwrap(
            try probe("query-via-wide", in: cap).heard.first { $0.repeatedByDigi })

        let tracker = APRSPingTracker()
        tracker.isOurs = { $0.uppercased().hasPrefix("ORACLE") }
        let subject = PassthroughSubject<Packet, Never>()
        tracker.follow(subject.eraseToAnyPublisher())

        tracker.record(ping: cap.digipeater, query: "?APRSP", reach: .wide)
        subject.send(try packet(repeated))

        // `follow` hops to the main queue on purpose; let that land.
        let landed = expectation(description: "digipeat observed")
        DispatchQueue.main.async { landed.fulfill() }
        await fulfillment(of: [landed], timeout: 2)

        let ping = try XCTUnwrap(tracker.outcome(for: cap.digipeater))
        XCTAssertTrue(ping.heardUs, "a real digipeat of our own frame is reception")
        XCTAssertNotNil(tracker.repeatedUs(cap.digipeater))

        tracker.now = { Date().addingTimeInterval(APRSPingTracker.window + 1) }
        tracker.expire()
        let settled = try XCTUnwrap(tracker.outcome(for: cap.digipeater))
        XCTAssertEqual(settled.outcome, .silent)
        XCTAssertTrue(settled.heardUs)
        XCTAssertTrue(APRSPingPresentation.line(settled).hasPrefix("It hears us"),
                      APRSPingPresentation.line(settled))
    }

    /// The counter-case: a direct ping to the same station produces no
    /// digipeat evidence, and the app must not imply the station went quiet.
    func testADirectPingProducesNoDigipeatEvidence() async throws {
        let cap = try capture()
        let direct = try XCTUnwrap(
            try probe("beacon-direct", in: cap).heard.first { $0.isOurs })

        let tracker = APRSPingTracker()
        tracker.isOurs = { $0.uppercased().hasPrefix("ORACLE") }
        let subject = PassthroughSubject<Packet, Never>()
        tracker.follow(subject.eraseToAnyPublisher())

        tracker.record(ping: cap.digipeater, query: "?APRSP", reach: .direct)
        subject.send(try packet(direct))
        let landed = expectation(description: "frame observed")
        DispatchQueue.main.async { landed.fulfill() }
        await fulfillment(of: [landed], timeout: 2)

        XCTAssertEqual(tracker.outcome(for: cap.digipeater)?.heardUs, false)

        // The reach explanation belongs to a ping that has actually gone
        // quiet: while it is still waiting there is nothing to explain.
        tracker.now = { Date().addingTimeInterval(APRSPingTracker.window + 1) }
        tracker.expire()
        let settled = try XCTUnwrap(tracker.outcome(for: cap.digipeater))
        XCTAssertEqual(settled.outcome, .silent)
        XCTAssertFalse(settled.heardUs)
        XCTAssertTrue(APRSPingPresentation.help(settled).contains("went direct"),
                      "the tooltip must say why no evidence was even possible: "
                      + APRSPingPresentation.help(settled))
    }
}
