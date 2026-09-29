import XCTest
@testable import AXTerm

/// Every APRS type AXTerm can read, put on the air and read back by somebody else.
///
/// AXTerm transmits positions and messages. Objects, items, telemetry, weather,
/// status and Mic-E are parse-only, so no round trip through AXTerm can ever
/// prove them: our encoder and our decoder agreeing is one implementation
/// agreeing with itself. `TestRig/scripts/aprs_zoo.py` therefore transmits one
/// frame of each type through a real 1200-baud AFSK modem, and Direwolf — a
/// mature parser that is neither AXTerm nor Xastir — says in its log what it
/// heard. This suite asserts AXTerm reaches Direwolf's conclusions.
///
/// Most frames are real transmissions off the operator's own channel
/// (2026-09-09); the rest are synthesised to APRS 1.01, and Direwolf decoding
/// them at all is what validates the synthesis, since it simply fails to
/// decode a malformed frame.
///
/// Regenerate with:
///
///     docker compose --profile rfnet up -d
///     python3 aprs_zoo.py --out ../../AXTermTests/Fixtures/aprs-zoo.json
final class APRSZooTests: XCTestCase {

    // MARK: - The fixture

    struct Frame: Decodable {
        let name: String
        let src: String
        let dest: String
        let frameHex: String
        let infoHex: String
        let provenance: String
        /// Direwolf's own words, one line per line of its log.
        let direwolf: [String]

        enum CodingKeys: String, CodingKey {
            case name, src, dest, provenance
            case frameHex = "frame_hex"
            case infoHex = "info_hex"
            case direwolf = "decoded_by_direwolf"
        }

        var info: Data { Data(hexString: infoHex) ?? Data() }
        /// Everything Direwolf said about the frame, for field scraping.
        var said: String { direwolf.joined(separator: ", ") }
    }

    private struct Capture: Decodable {
        let capturedAt: String
        let channel: String
        let frames: [Frame]

        enum CodingKeys: String, CodingKey {
            case channel, frames
            case capturedAt = "captured_at"
        }
    }

    private static let zoo: [String: Frame] = {
        guard let url = Bundle(for: APRSZooTests.self)
                .url(forResource: "aprs-zoo", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let capture = try? JSONDecoder().decode(Capture.self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: capture.frames.map { ($0.name, $0) })
    }()

    private func frame(_ name: String) throws -> Frame {
        try XCTUnwrap(Self.zoo[name], "aprs-zoo.json has no frame named \(name)")
    }

    // MARK: - Reading Direwolf

    /// Direwolf prints `N 39 40.0000, W 104 45.0000`.
    private func direwolfPosition(_ said: String) -> (lat: Double, lon: Double)? {
        guard let m = capture(#"([NS]) (\d+) ([\d.]+), ([EW]) (\d+) ([\d.]+)"#, in: said),
              let latDeg = Double(m[2]), let latMin = Double(m[3]),
              let lonDeg = Double(m[5]), let lonMin = Double(m[6])
        else { return nil }
        let lat = (latDeg + latMin / 60) * (m[1] == "S" ? -1 : 1)
        let lon = (lonDeg + lonMin / 60) * (m[4] == "W" ? -1 : 1)
        return (lat, lon)
    }

    private func number(_ pattern: String, in said: String) -> Double? {
        guard let m = capture(pattern, in: said) else { return nil }
        return Double(m[1])
    }

    /// Capture groups of the first match, group 0 first, or nil.
    private func capture(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0..<m.numberOfRanges).map {
            guard let r = Range(m.range(at: $0), in: text) else { return "" }
            return String(text[r])
        }
    }

    // MARK: - The fixture is real

    /// A fixture regenerated against a rig that was not actually passing audio
    /// would be a file full of empty decodes that every other test in here
    /// would then vacuously pass. This is the guard.
    func testEveryFrameWasHeardAndDecodedOnTheAir() throws {
        XCTAssertEqual(Self.zoo.count, 8, "aprs-zoo.json did not load")
        for (name, f) in Self.zoo {
            XCTAssertFalse(f.direwolf.isEmpty,
                           "\(name) was transmitted but Direwolf did not decode it")
            XCTAssertFalse(f.provenance.isEmpty, "\(name) has no provenance")
        }
    }

    /// The information field the test parses is the one that was on the air:
    /// the recorded AX.25 frame decodes to the recorded source, destination and
    /// info. Without this the fixture could pair a frame with another frame's
    /// bytes and nothing would notice.
    func testTheRecordedFramesCarryTheRecordedInformation() throws {
        for (name, f) in Self.zoo {
            let raw = try XCTUnwrap(Data(hexString: f.frameHex), "\(name): bad hex")
            let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: raw), "\(name) did not decode")
            XCTAssertEqual(decoded.from?.display, f.src, name)
            XCTAssertEqual(decoded.to?.display, f.dest, name)
            XCTAssertEqual(decoded.info, f.info, "\(name): info field is not what was sent")
        }
    }

    // MARK: - Positions

    /// The four frames that carry a fix, each read to the same place Direwolf
    /// read it. A tenth of a second of arc is far tighter than either
    /// encoding's own resolution.
    func testEveryPositionAgreesWithDirewolf() throws {
        for name in ["mic-e", "compressed-position", "uncompressed-position", "weather"] {
            let f = try frame(name)
            let theirs = try XCTUnwrap(direwolfPosition(f.said),
                                       "\(name): no position in Direwolf's decode")
            let ours = try XCTUnwrap(APRSParser.parse(destination: f.dest, info: f.info),
                                     "\(name): AXTerm found no position")
            XCTAssertEqual(ours.latitude, theirs.lat, accuracy: 0.0001, "\(name) latitude")
            XCTAssertEqual(ours.longitude, theirs.lon, accuracy: 0.0001, "\(name) longitude")
        }
    }

    /// Each encoding is identified as itself. A compressed report read as an
    /// uncompressed one would still produce coordinates — wrong ones — so the
    /// kind is part of the claim.
    func testEachEncodingIsRecognisedAsItself() throws {
        let expected: [String: APRSReport.Kind] = [
            "mic-e": .micE,
            "compressed-position": .compressed,
            "uncompressed-position": .uncompressed,
            "weather": .uncompressed,
        ]
        for (name, kind) in expected {
            let f = try frame(name)
            let ours = try XCTUnwrap(APRSParser.parse(destination: f.dest, info: f.info), name)
            XCTAssertEqual(ours.kind, kind, name)
        }
    }

    /// APRS 1.01 ch.10: a Mic-E frame's latitude, its N/S and E/W signs and its
    /// message bits live in the *AX.25 destination*, not the information field.
    /// This is the one APRS type that cannot be tested from its payload alone,
    /// and the reason the fixture records the destination at all — so change
    /// the destination and the position must move.
    func testMicELatitudeComesFromTheDestinationField() throws {
        let f = try frame("mic-e")
        let real = try XCTUnwrap(APRSParser.parse(destination: f.dest, info: f.info))
        XCTAssertEqual(f.dest, "SYTPZZ")
        let moved = try XCTUnwrap(APRSParser.parse(destination: "S1TPZZ", info: f.info))
        XCTAssertNotEqual(moved.latitude, real.latitude,
                          "the destination field is being ignored")
    }

    /// Course, speed and altitude out of the Mic-E block, as Direwolf read
    /// them. Its "0 MPH" and our zero knots are the same standstill; a moving
    /// station would need the unit conversion, and none of the captured
    /// frames were moving.
    func testMicEMotionAndAltitudeAgreeWithDirewolf() throws {
        let f = try frame("mic-e")
        let ours = try XCTUnwrap(APRSParser.parse(destination: f.dest, info: f.info))
        XCTAssertEqual(Double(try XCTUnwrap(ours.courseDegrees)),
                       try XCTUnwrap(number(#"course (\d+)"#, in: f.said)), "course")
        XCTAssertEqual(number(#"(\d+) MPH"#, in: f.said), 0, "the capture was stationary")
        XCTAssertNil(ours.speedKnots, "zero speed is absence, not a reading")
        XCTAssertEqual(Double(try XCTUnwrap(ours.altitudeFeet)),
                       try XCTUnwrap(number(#"alt (\d+) ft"#, in: f.said)),
                       accuracy: 1, "Mic-E altitude (base-91 metres, −10000)")
    }

    /// `/A=` in a compressed report's comment, which our parser has to strip
    /// out of the comment as well as read.
    func testCompressedAltitudeAgreesAndLeavesTheComment() throws {
        let f = try frame("compressed-position")
        let ours = try XCTUnwrap(APRSParser.parse(destination: f.dest, info: f.info))
        XCTAssertEqual(Double(try XCTUnwrap(ours.altitudeFeet)),
                       try XCTUnwrap(number(#"alt (\d+) ft"#, in: f.said)),
                       accuracy: 1)
        XCTAssertEqual(ours.comment, f.direwolf.last, "the comment Direwolf was left with")
    }

    /// Mic-E hides four things in what looks like the comment: a type code
    /// naming the radio's family, a signature naming the model, an altitude in
    /// base-91, and a repeater listing. All four are read into their own
    /// fields and taken out of the text.
    ///
    /// The signature is the one place this suite cannot simply defer to the
    /// recording. `decode_aprs` produced it without its `tocalls.yaml`, so it
    /// could not identify the radio and left the two characters it signed with
    /// — `_1`, a Yaesu — sitting in the comment, which is all it had left of
    /// this frame. Loaded with that table it consumes them exactly as we do.
    /// Asserting against the raw line would pin AXTerm to a Direwolf that was
    /// missing a file.
    func testMicECommentDropsEveryFieldItAlreadyRead() throws {
        let f = try frame("mic-e")
        let ours = try XCTUnwrap(APRSParser.parse(destination: f.dest, info: f.info))

        XCTAssertNotNil(ours.altitudeFeet, "the altitude is read")
        XCTAssertEqual(ours.frequency?.megahertz ?? 0, 147.210, accuracy: 0.0005)
        XCTAssertEqual(ours.frequency?.tone, .ctcss(hertz: 100.0))
        XCTAssertEqual(ours.frequency?.offsetKilohertz, 600)

        XCTAssertEqual(f.direwolf.last, "_1",
                       "Direwolf was left holding the signature it had no table to name")
        XCTAssertEqual(ours.comment, "",
                       "and with that read too, the operator wrote nothing at all")
    }

    /// Direwolf prints the plain remainder of the payload as the last line.
    /// Where the type has no structured tail, that is exactly our comment.
    /// Mic-E is not in this list: its tail is structured to the last character,
    /// and `testMicECommentDropsEveryFieldItAlreadyRead` covers it.
    func testCommentsAgreeWhereDirewolfLeavesThemWhole() throws {
        for name in ["uncompressed-position", "compressed-position"] {
            let f = try frame(name)
            let ours = try XCTUnwrap(APRSParser.parse(destination: f.dest, info: f.info), name)
            XCTAssertEqual(ours.comment, f.direwolf.last, name)
        }
    }

    // MARK: - Objects and items

    /// APRS 1.01 ch.11. An object is a thing a station puts on the map that is
    /// not the station — a repeater, an incident, a shelter — and the grid-down
    /// case turns on reading them right.
    func testObjectAgreesWithDirewolf() throws {
        let f = try frame("object")
        let ours = try XCTUnwrap(APRSObjectReport.parse(info: f.info), "no object parsed")
        let theirs = try XCTUnwrap(direwolfPosition(f.said))
        XCTAssertEqual(ours.kind, .object)
        XCTAssertEqual(ours.name, capture(#""([^"]+)""#, in: f.said)?[1])
        XCTAssertTrue(ours.isLive, "the `*` in the wire format means live")
        XCTAssertEqual(ours.latitude, theirs.lat, accuracy: 0.0001)
        XCTAssertEqual(ours.longitude, theirs.lon, accuracy: 0.0001)
        XCTAssertEqual(ours.comment, f.direwolf.last)
    }

    func testItemAgreesWithDirewolf() throws {
        let f = try frame("item")
        let ours = try XCTUnwrap(APRSObjectReport.parse(info: f.info), "no item parsed")
        let theirs = try XCTUnwrap(direwolfPosition(f.said))
        XCTAssertEqual(ours.kind, .item)
        XCTAssertEqual(ours.name, capture(#""([^"]+)""#, in: f.said)?[1])
        XCTAssertTrue(ours.isLive)
        XCTAssertEqual(ours.latitude, theirs.lat, accuracy: 0.0001)
        XCTAssertEqual(ours.longitude, theirs.lon, accuracy: 0.0001)
        XCTAssertEqual(ours.comment, f.direwolf.last)
    }

    // MARK: - Telemetry

    /// `T#seq,a1…a5,bbbbbbbb`. Direwolf names every channel it read, so a
    /// mis-split — the classic off-by-one that shifts every channel — cannot
    /// survive this.
    func testTelemetryChannelsAgreeWithDirewolf() throws {
        let f = try frame("telemetry")
        let ours = try XCTUnwrap(APRSTelemetry.parseFrame(info: f.info), "no telemetry parsed")
        XCTAssertEqual(Double(ours.sequence), number(#"Seq=(\d+)"#, in: f.said))
        for channel in 1...5 {
            XCTAssertEqual(ours.analogue[channel - 1],
                           try XCTUnwrap(number(#"A\#(channel)=(\d+)"#, in: f.said)),
                           "analogue channel \(channel)")
        }
        XCTAssertEqual(ours.bits.count, 8)
        for bit in 1...8 {
            let theirs = try XCTUnwrap(number(#"D\#(bit)=(\d)"#, in: f.said))
            XCTAssertEqual(ours.bits[bit - 1], theirs == 1, "digital bit \(bit)")
        }
    }

    // MARK: - Weather

    /// APRS 1.01 ch.12. Direwolf reports every field it recognised, which is
    /// the closest thing to an independent reading of a weather beacon we can
    /// get — and the place a filler-versus-zero mistake would show up, since
    /// `r000` is a real zero and `r...` is no sensor.
    func testWeatherFieldsAgreeWithDirewolf() throws {
        let f = try frame("weather")
        let report = try XCTUnwrap(APRSParser.parse(destination: f.dest, info: f.info))
        let wx = try XCTUnwrap(report.weather, "AXTerm read no weather from a `_` station")
        XCTAssertEqual(report.symbolCode, "_", "the weather symbol is what selects the parse")

        XCTAssertEqual(Double(try XCTUnwrap(wx.temperatureF)),
                       try XCTUnwrap(number(#"temperature (-?\d+)"#, in: f.said)))
        XCTAssertEqual(Double(try XCTUnwrap(wx.humidityPercent)),
                       try XCTUnwrap(number(#"humidity (\d+)"#, in: f.said)))
        XCTAssertEqual(Double(try XCTUnwrap(wx.windDirectionDegrees)),
                       try XCTUnwrap(number(#"direction (\d+)"#, in: f.said)))
        XCTAssertEqual(Double(try XCTUnwrap(wx.windSpeedMPH)),
                       try XCTUnwrap(number(#"wind ([\d.]+) mph"#, in: f.said)))
        XCTAssertEqual(Double(try XCTUnwrap(wx.gustMPH)),
                       try XCTUnwrap(number(#"gust (\d+)"#, in: f.said)))
        XCTAssertEqual(wx.rainLastHourHundredths, 0, "r000 is a measured zero")

        // Direwolf converts to inches of mercury; we keep tenths of millibars
        // as sent. Comparing them at all is the point — a unit slip is exactly
        // the bug a single-implementation test cannot see.
        let inHg = try XCTUnwrap(number(#"barometer ([\d.]+)"#, in: f.said))
        XCTAssertEqual(Double(try XCTUnwrap(wx.pressureTenthsMillibars)) / 10,
                       inHg * 33.8639, accuracy: 1.0, "barometric pressure")
    }

    // MARK: - What is not a position

    /// Telemetry and status carry no fix. A parser that guessed one would put
    /// stations on the map at coordinates nobody transmitted, which is worse
    /// than not plotting them.
    func testFramesWithoutAFixYieldNoPosition() throws {
        for name in ["telemetry", "status"] {
            let f = try frame(name)
            XCTAssertNil(APRSParser.parse(destination: f.dest, info: f.info),
                         "\(name) is not a position report")
            XCTAssertNil(APRSObjectReport.parse(info: f.info),
                         "\(name) is not an object")
        }
    }

    /// The status frame is what Direwolf says it is, and its text is the
    /// payload after the `>`. AXTerm has no status parser; this pins the
    /// fixture so that when one is written it has something to be right about.
    func testStatusIsCarriedVerbatimAfterTheDataTypeIdentifier() throws {
        let f = try frame("status")
        XCTAssertTrue(f.direwolf.first?.hasPrefix("Status Report") == true, f.said)
        let text = String(decoding: f.info.dropFirst(), as: UTF8.self)
        XCTAssertEqual(text, f.direwolf.last)
    }
}
