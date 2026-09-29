#if os(macOS)
import XCTest
@testable import AXTerm

/// AXTerm's parsers against Direwolf's, over half an hour of real traffic.
///
/// `APRSZooTests` proves one frame of each type. This is the other axis: every
/// frame two feeds actually carried in a thirty-minute window — the operator's
/// own radios on 144.390, and the APRS-IS stream aprs.fi displays for the same
/// area — decoded by `decode_aprs` and then by us. Live traffic is where the
/// malformed, the truncated and the merely unusual live, and a decoder that
/// only ever sees well-formed fixtures has not been tested on the air.
///
/// Regenerate with `TestRig/scripts/live_feed_capture.sh`.
final class LiveFeedParityTests: XCTestCase {

    struct Record: Decodable {
        let feed: String            // "rf" (our radios) or "is" (APRS-IS)
        let at: String
        let src: String
        let dest: String
        let info: String
        let hex: String
        /// Direwolf's decode, its summary line first.
        let direwolf: [String]
        /// The position Direwolf read, [lat, lon], or nil for a frame with none.
        let position: [Double]?
    }

    private struct Capture: Decodable {
        let window: [String]
        let records: [Record]
    }

    private static let records: [Record] = {
        guard let url = Bundle(for: LiveFeedParityTests.self)
                .url(forResource: "live-feed-parity", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let capture = try? JSONDecoder().decode(Capture.self, from: data)
        else { return [] }
        return capture.records
    }()

    /// The information field as it came off the air, bytes intact. Mic-E and
    /// compressed reports are binary; the JSON carries hex for that reason.
    private func info(_ r: Record) -> Data { Data(hexString: r.hex) ?? Data() }

    /// Whether this frame could have arrived over the air at all.
    ///
    /// APRS-IS carries stations that have no AX.25 existence: D-Star and MMDVM
    /// gateways with letter SSIDs (`W0KVZ-N`), LoRa gateways with SSID 40, and
    /// `WINLINK`, which is seven characters. They are injected straight to the
    /// servers. Direwolf refuses them because it parses a TNC2 line as AX.25;
    /// we parse an information field and neither know nor care. Comparing the
    /// two on those frames measures the harness, not the decoder — and no such
    /// frame can ever reach AXTerm from a radio.
    private func couldBeOnAir(_ r: Record) -> Bool {
        let parts = r.src.split(separator: "-", maxSplits: 1)
        guard let call = parts.first, call.count <= 6,
              call.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        guard parts.count == 2 else { return true }
        guard let ssid = Int(parts[1]), (0...15).contains(ssid) else { return false }
        return true
    }

    /// Whatever position AXTerm can find, from whichever parser owns the type.
    /// Direwolf reports one number for positions, objects and items alike; we
    /// split them across two parsers, so the comparison has to try both.
    private func ourPosition(_ r: Record) -> (lat: Double, lon: Double)? {
        if let p = APRSParser.parse(destination: r.dest, info: info(r)) {
            return (p.latitude, p.longitude)
        }
        if let o = APRSObjectReport.parse(info: info(r)) {
            return (o.latitude, o.longitude)
        }
        return nil
    }

    /// Long assertion messages do not survive to xcodebuild's stdout, and the
    /// point of this suite is the listing, not the boolean. It goes to a file.
    private func report(_ title: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        let text = "== \(title) (\(lines.count)) ==\n" + lines.joined(separator: "\n") + "\n"
        let path = NSTemporaryDirectory() + "axterm_live_parity.txt"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        }
    }

    func testTheCaptureLoaded() {
        XCTAssertGreaterThan(Self.records.count, 50,
                             "live-feed-parity.json did not load or is too thin to mean anything")
    }

    /// Where Direwolf found a position, so must we, and the same one.
    ///
    /// A tenth of a minute of arc is looser than either encoding's resolution
    /// and tighter than any real disagreement: a wrong hemisphere, a wrong
    /// base-91 divisor or a mis-split Mic-E destination all miss by miles.
    func testEveryPositionDirewolfFindsWeFindToo() throws {
        var missed: [String] = []
        var wrong: [String] = []
        var compared = 0
        for r in Self.records where couldBeOnAir(r) {
            guard let theirs = r.position, theirs.count == 2 else { continue }
            // 0°N 0°E is the no-fix sentinel, which we deliberately refuse to
            // call a position — see `APRSNoFixTests`. Direwolf reports it
            // literally; disagreeing with it here is the point.
            if theirs[0] == 0 && theirs[1] == 0 { continue }
            guard let ours = ourPosition(r) else {
                missed.append("\(r.src)>\(r.dest) \(r.direwolf.first ?? "") — \(r.info.prefix(60))")
                continue
            }
            compared += 1
            if abs(ours.lat - theirs[0]) > 0.0002 || abs(ours.lon - theirs[1]) > 0.0002 {
                wrong.append("\(r.src): ours \(ours.lat),\(ours.lon) theirs \(theirs[0]),\(theirs[1])")
            }
        }
        report("Direwolf located, we did not", missed)
        report("located differently", wrong)
        // A comparison that quietly stops comparing is the failure mode this
        // suite already had once, when the fixture would not decode and three
        // tests passed over an empty array.
        XCTAssertGreaterThan(compared, 300,
                             "only \(compared) frames were actually compared")
        XCTAssertTrue(missed.isEmpty,
                      "\(missed.count) frames Direwolf located and we did not:\n"
                      + missed.joined(separator: "\n"))
        XCTAssertTrue(wrong.isEmpty,
                      "\(wrong.count) frames located differently:\n" + wrong.joined(separator: "\n"))
    }

    /// And the other direction: a position we invent where Direwolf sees none
    /// would put a station on the map at coordinates nobody transmitted.
    func testWeInventNoPositionDirewolfCannotSee() throws {
        var invented: [String] = []
        for r in Self.records where r.position == nil && couldBeOnAir(r) {
            if let ours = ourPosition(r) {
                invented.append("\(r.src)>\(r.dest) \(ours.lat),\(ours.lon) "
                                + "— \(r.direwolf.first ?? "") — \(r.info.prefix(60))")
            }
        }
        report("we located, Direwolf did not", invented)
        XCTAssertTrue(invented.isEmpty,
                      "\(invented.count) frames we located and Direwolf did not:\n"
                      + invented.joined(separator: "\n"))
    }

    /// Telemetry is its own parser and its own chance to be off by one.
    func testTelemetryAgreesAcrossTheCapture() throws {
        var disagreed: [String] = []
        for r in Self.records where couldBeOnAir(r) {
            // Direwolf labels the PARM/UNIT/EQNS/BITS definition messages
            // "Telemetry" as well, and those are a different parser: they are
            // messages addressed to the station itself, not `T#` reports.
            let summary = r.direwolf.joined(separator: " ")
            guard summary.contains("Telemetry"), r.info.hasPrefix("T#") else { continue }
            guard let ours = APRSTelemetry.parseFrame(info: info(r)) else {
                disagreed.append("\(r.src): we parsed no telemetry from \(r.info.prefix(50))")
                continue
            }
            let said = r.direwolf.joined(separator: " ")
            for channel in 1...5 {
                guard let range = said.range(of: "A\(channel)=") else { continue }
                let digits = said[range.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "-" }
                guard let theirs = Double(digits) else { continue }
                if ours.analogue[channel - 1] != theirs {
                    disagreed.append("\(r.src) A\(channel): ours \(ours.analogue[channel - 1]) theirs \(theirs)")
                }
            }
        }
        report("telemetry disagreement", disagreed)
        XCTAssertTrue(disagreed.isEmpty, disagreed.joined(separator: "\n"))
    }
}
#endif
