//
//  StationActivityInsightsTests.swift
//  AXTermTests
//
//  Role inference, traffic classification, hourly profiles, airtime ranking,
//  and observed-session reconstruction — all from protocol facts, never from
//  message-content guessing.
//

import XCTest
@testable import AXTerm

final class StationActivityInsightsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func makePacket(
        timestamp: Date,
        from: String,
        to: String,
        via: [AX25Address] = [],
        frameType: FrameType = .ui,
        control: UInt8 = 0x03,
        info: String? = nil
    ) -> Packet {
        let data = info?.data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via,
            frameType: frameType,
            control: control,
            info: data,
            infoText: info
        )
    }

    // MARK: - Role inference

    func testRoleInferenceFromProtocolSignals() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let packets = [
            // DRLNOD sends a NET/ROM broadcast -> node
            makePacket(timestamp: base, from: "DRLNOD", to: "NODES", frameType: .ui),
            // K0EPI-1 announces mail -> bbs
            makePacket(timestamp: base.addingTimeInterval(1), from: "K0EPI-1", to: "MAIL", frameType: .ui),
            // K4DIG actually repeated a frame -> digipeater
            makePacket(
                timestamp: base.addingTimeInterval(2),
                from: "W1AAA", to: "K2BBB",
                via: [AX25Address(call: "K4DIG", repeated: true)],
                frameType: .ui
            ),
            // W1AAA <-> K2BBB exchange I frames -> connected users
            makePacket(timestamp: base.addingTimeInterval(3), from: "W1AAA", to: "K2BBB", frameType: .i, control: 0x00, info: "hello"),
            // KB5YZB-7 sends an SID software banner in an I frame -> bbs
            makePacket(timestamp: base.addingTimeInterval(4), from: "KB5YZB-7", to: "K0EPI-7", frameType: .i, control: 0x00, info: "[BPQ-6.0.24-B1FWIHJM$]")
        ]

        let roles = StationRoleInference.inferRoles(packets: packets, identityMode: .ssid)

        XCTAssertTrue(roles["DRLNOD"]?.contains(.node) ?? false)
        XCTAssertTrue(roles["K0EPI-1"]?.contains(.bbs) ?? false)
        XCTAssertTrue(roles["K4DIG"]?.contains(.digipeater) ?? false)
        XCTAssertTrue(roles["W1AAA"]?.contains(.connectedUser) ?? false)
        XCTAssertTrue(roles["K2BBB"]?.contains(.connectedUser) ?? false)
        XCTAssertTrue(roles["KB5YZB-7"]?.contains(.bbs) ?? false)
        XCTAssertNil(roles["NODES"], "Service destinations never gain roles")
    }

    func testSIDBannerDetection() {
        XCTAssertTrue(StationRoleInference.isSIDBanner("[BPQ-6.0.24-B1FWIHJM$]"))
        XCTAssertTrue(StationRoleInference.isSIDBanner("[FBB-7.011-AB1FHMRX$]\r"))
        XCTAssertFalse(StationRoleInference.isSIDBanner("hello [not an sid]"))
        XCTAssertFalse(StationRoleInference.isSIDBanner("just chatting about [BPQ] nodes"))
    }

    // MARK: - Traffic classification

    func testTrafficClassificationUsesRolesNotContent() {
        let base = Date(timeIntervalSince1970: 1_700_001_000)
        let roles: [String: Set<StationRole>] = [
            "DRLNOD": [.node],
            "K0EPI-1": [.bbs]
        ]

        // Routing broadcast
        XCTAssertEqual(
            TrafficClassifier.classify(
                packet: makePacket(timestamp: base, from: "DRLNOD", to: "NODES", frameType: .ui),
                roles: roles, identityMode: .ssid
            ),
            .routing
        )
        // Beacon
        XCTAssertEqual(
            TrafficClassifier.classify(
                packet: makePacket(timestamp: base, from: "W1AAA", to: "BEACON", frameType: .ui),
                roles: roles, identityMode: .ssid
            ),
            .beacon
        )
        // I frame with an infrastructure endpoint -> BBS/Node traffic
        XCTAssertEqual(
            TrafficClassifier.classify(
                packet: makePacket(timestamp: base, from: "W1AAA", to: "DRLNOD", frameType: .i, control: 0x00, info: "c kb5yzb-7"),
                roles: roles, identityMode: .ssid
            ),
            .bbsNode
        )
        // I frame between two regular stations -> chat
        XCTAssertEqual(
            TrafficClassifier.classify(
                packet: makePacket(timestamp: base, from: "W1AAA", to: "K2BBB", frameType: .i, control: 0x00, info: "hi fred"),
                roles: roles, identityMode: .ssid
            ),
            .chat
        )
        // Supervisory frame -> overhead
        XCTAssertEqual(
            TrafficClassifier.classify(
                packet: makePacket(timestamp: base, from: "W1AAA", to: "K2BBB", frameType: .s, control: 0x01),
                roles: roles, identityMode: .ssid
            ),
            .overhead
        )
    }

    func testActivityByHourBucketsCorrectly() {
        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let packets = [
            makePacket(timestamp: dayStart.addingTimeInterval(9 * 3600), from: "W1AAA", to: "BEACON", frameType: .ui),
            makePacket(timestamp: dayStart.addingTimeInterval(9 * 3600 + 60), from: "W1AAA", to: "K2BBB", frameType: .i, control: 0x00, info: "hi"),
            makePacket(timestamp: dayStart.addingTimeInterval(21 * 3600), from: "W1AAA", to: "K2BBB", frameType: .i, control: 0x00, info: "gm")
        ]
        let profile = ActivityByHourCalculator.profile(
            packets: packets, roles: [:], identityMode: .ssid, calendar: calendar
        )
        XCTAssertEqual(profile.hours[9][.beacon], 1)
        XCTAssertEqual(profile.hours[9][.chat], 1)
        XCTAssertEqual(profile.hours[21][.chat], 1)
        XCTAssertEqual(profile.totalCount, 3)
    }

    // MARK: - Airtime ranking

    func testAirtimeChargesSenderAndRepeatingDigi() {
        let base = Date(timeIntervalSince1970: 1_700_002_000)
        let packets = [
            // 100-byte frame from W1AAA repeated by K4DIG: both pay the airtime.
            makePacket(
                timestamp: base, from: "W1AAA", to: "K2BBB",
                via: [AX25Address(call: "K4DIG", repeated: true), AX25Address(call: "K5REQ", repeated: false)],
                frameType: .ui, info: String(repeating: "x", count: 100)
            ),
            // Short frame from K2BBB, no digi.
            makePacket(timestamp: base.addingTimeInterval(1), from: "K2BBB", to: "W1AAA", frameType: .ui, info: "ok")
        ]

        let ranking = AirtimeRanking.rank(packets: packets, identityMode: .ssid, limit: 5)
        let byCall = Dictionary(uniqueKeysWithValues: ranking.map { ($0.callsign, $0.airtimeSeconds) })

        let bigFrame = AnalyticsStyle.Channel.frameAirtimeSeconds(payloadBytes: 100)
        XCTAssertEqual(byCall["W1AAA"] ?? 0, bigFrame, accuracy: 0.001)
        XCTAssertEqual(byCall["K4DIG"] ?? 0, bigFrame, accuracy: 0.001,
                       "A repeating digi pays the same airtime as the sender")
        XCTAssertNil(byCall["K5REQ"], "A requested-but-unused digi transmitted nothing")
        // Sender and digi transmitted identical airtime; ties break alphabetically.
        XCTAssertEqual(ranking.prefix(2).map(\.callsign), ["K4DIG", "W1AAA"])
        XCTAssertEqual(ranking.last?.callsign, "K2BBB")
    }

    // MARK: - Observed sessions

    private func sabm(_ from: String, _ to: String, at time: Date) -> Packet {
        makePacket(timestamp: time, from: from, to: to, frameType: .u, control: 0x2F) // SABM P=0 -> 0x2F is SABM+P; fine either way
    }

    private func disc(_ from: String, _ to: String, at time: Date) -> Packet {
        makePacket(timestamp: time, from: from, to: to, frameType: .u, control: 0x43)
    }

    func testConnectedSessionReconstruction() {
        let base = Date(timeIntervalSince1970: 1_700_003_000)
        var packets: [Packet] = [sabm("W1AAA", "K2BBB", at: base)]
        for offset in 0..<4 {
            packets.append(makePacket(
                timestamp: base.addingTimeInterval(Double(offset + 1) * 10),
                from: "W1AAA", to: "K2BBB", frameType: .i, control: 0x00, info: "data\(offset)"
            ))
        }
        packets.append(disc("W1AAA", "K2BBB", at: base.addingTimeInterval(120)))

        let sessions = SessionObservationCalculator.sessions(
            packets: packets, identityMode: .ssid, windowEnd: base.addingTimeInterval(3600)
        )

        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertEqual(session.stationA, "W1AAA")
        XCTAssertEqual(session.stationB, "K2BBB")
        XCTAssertEqual(session.start, base)
        XCTAssertEqual(session.end, base.addingTimeInterval(120))
        XCTAssertEqual(session.iFrameCount, 4)
        XCTAssertEqual(session.byteCount, 20)
    }

    func testIdlePollingPairRecognizedAsSession() {
        // A connected pair we joined mid-session: RR polling only, no SABM seen.
        let base = Date(timeIntervalSince1970: 1_700_004_000)
        var packets: [Packet] = []
        for offset in 0..<6 {
            let fromEven = offset % 2 == 0
            let from = fromEven ? "K0NTS-1" : "N0CVL-10"
            let to = fromEven ? "N0CVL-10" : "K0NTS-1"
            let timestamp = base.addingTimeInterval(Double(offset) * 30)
            packets.append(makePacket(timestamp: timestamp, from: from, to: to, frameType: .s, control: 0x11)) // RR
        }

        let sessions = SessionObservationCalculator.sessions(
            packets: packets, identityMode: .ssid, windowEnd: base.addingTimeInterval(200)
        )
        XCTAssertEqual(sessions.count, 1, "Sustained supervisory polling is a live session")
        XCTAssertNil(sessions[0].end, "Still active at the window end")
    }

    func testInactivityGapSplitsSessions() {
        let base = Date(timeIntervalSince1970: 1_700_005_000)
        var packets: [Packet] = []
        for offset in 0..<3 {
            packets.append(makePacket(
                timestamp: base.addingTimeInterval(Double(offset) * 10),
                from: "W1AAA", to: "K2BBB", frameType: .i, control: 0x00, info: "one"
            ))
        }
        // 20 minutes of silence, then more traffic: a second session.
        for offset in 0..<3 {
            packets.append(makePacket(
                timestamp: base.addingTimeInterval(1200 + Double(offset) * 10),
                from: "W1AAA", to: "K2BBB", frameType: .i, control: 0x00, info: "two"
            ))
        }

        let sessions = SessionObservationCalculator.sessions(
            packets: packets, identityMode: .ssid, windowEnd: base.addingTimeInterval(5000)
        )
        XCTAssertEqual(sessions.count, 2, "A long quiet gap ends the first session")
    }

    func testSABMRetryBurstIsOneConnectAttempt() {
        // AX.25 retries SABM on its T1 timer (~every 6 s) when nobody answers.
        // Six SABMs are ONE failed connect attempt, not six sessions.
        let base = Date(timeIntervalSince1970: 1_700_009_000)
        let packets = (0..<6).map { offset in
            makePacket(
                timestamp: base.addingTimeInterval(Double(offset) * 6),
                from: "K0NTS", to: "KF0BPN", frameType: .u, control: 0x2F // SABM
            )
        }

        let sessions = SessionObservationCalculator.sessions(
            packets: packets, identityMode: .station, windowEnd: base.addingTimeInterval(3600)
        )

        XCTAssertEqual(sessions.count, 1, "A SABM retry burst is a single connect attempt")
        let attempt = sessions[0]
        XCTAssertFalse(attempt.wasEstablished, "Nobody ever answered")
        XCTAssertEqual(attempt.frameCount, 6)
        XCTAssertEqual(attempt.start, base)
    }

    func testRefusedConnectDMPingPongIsOneAttempt() {
        // A busy station answers every SABM with DM: still one attempt, not
        // a session per SABM/DM pair.
        let base = Date(timeIntervalSince1970: 1_700_009_500)
        var packets: [Packet] = []
        for attempt in 0..<3 {
            let t = base.addingTimeInterval(Double(attempt) * 8)
            packets.append(makePacket(timestamp: t, from: "K0NTS", to: "KF0BPN", frameType: .u, control: 0x2F)) // SABM
            packets.append(makePacket(timestamp: t.addingTimeInterval(1), from: "KF0BPN", to: "K0NTS", frameType: .u, control: 0x0F)) // DM
        }

        let sessions = SessionObservationCalculator.sessions(
            packets: packets, identityMode: .station, windowEnd: base.addingTimeInterval(3600)
        )

        XCTAssertEqual(sessions.count, 1, "SABM/DM ping-pong is one refused attempt")
        XCTAssertFalse(sessions[0].wasEstablished)
    }

    func testEstablishedSessionFollowedByReconnectIsTwoSessions() {
        // A real established session, then a fresh SABM shortly after: the new
        // connect genuinely starts a second session.
        let base = Date(timeIntervalSince1970: 1_700_009_800)
        var packets: [Packet] = [sabm("W1AAA", "K2BBB", at: base)]
        packets.append(makePacket(timestamp: base.addingTimeInterval(1), from: "K2BBB", to: "W1AAA", frameType: .u, control: 0x63)) // UA
        packets.append(makePacket(timestamp: base.addingTimeInterval(10), from: "W1AAA", to: "K2BBB", frameType: .i, control: 0x00, info: "hi"))
        packets.append(disc("W1AAA", "K2BBB", at: base.addingTimeInterval(60)))
        packets.append(sabm("W1AAA", "K2BBB", at: base.addingTimeInterval(120)))
        packets.append(makePacket(timestamp: base.addingTimeInterval(121), from: "K2BBB", to: "W1AAA", frameType: .u, control: 0x63)) // UA
        packets.append(makePacket(timestamp: base.addingTimeInterval(130), from: "W1AAA", to: "K2BBB", frameType: .i, control: 0x00, info: "again"))

        let sessions = SessionObservationCalculator.sessions(
            packets: packets, identityMode: .station, windowEnd: base.addingTimeInterval(5000)
        )

        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.allSatisfy(\.wasEstablished))
    }

    func testStrayFramesDoNotBecomeSessions() {
        let base = Date(timeIntervalSince1970: 1_700_006_000)
        let packets = [
            makePacket(timestamp: base, from: "W1AAA", to: "K2BBB", frameType: .s, control: 0x01),
            makePacket(timestamp: base.addingTimeInterval(5), from: "K2BBB", to: "W1AAA", frameType: .s, control: 0x01)
        ]
        let sessions = SessionObservationCalculator.sessions(
            packets: packets, identityMode: .ssid, windowEnd: base.addingTimeInterval(3600)
        )
        XCTAssertTrue(sessions.isEmpty, "Two stray RRs are not a session")
    }

    // MARK: - Directory

    func testInfrastructureStationsDoNotShowKeyboarderBadge() {
        // Real-world case: KB5YZB-7 is a BPQ node whose only connected-mode
        // traffic is answering inbound connects. Serving connections is not
        // evidence a human typed — the Keyboarder badge must not appear on
        // Node/BBS stations, while a regular station with I-frames keeps it.
        let base = Date(timeIntervalSince1970: 1_700_008_000)
        let packets = [
            // KB5YZB-7 answers a connect with its SID banner (I frame) -> bbs + connectedUser
            makePacket(timestamp: base, from: "KB5YZB-7", to: "K0EPI-7", frameType: .i, control: 0x00, info: "[BPQ-6.0.22.70-B2FWIHJM$]"),
            // K0EPI-7 types at the node -> connectedUser only
            makePacket(timestamp: base.addingTimeInterval(5), from: "K0EPI-7", to: "KB5YZB-7", frameType: .i, control: 0x00, info: "bbs")
        ]
        let roles = StationRoleInference.inferRoles(packets: packets, identityMode: .ssid)
        let directory = StationDirectoryBuilder.build(packets: packets, roles: roles, identityMode: .ssid)

        let node = directory.first { $0.callsign == "KB5YZB-7" }
        XCTAssertEqual(node?.roleBadges, ["BBS"],
                       "A BBS answering connects must not read as a keyboarder")
        let human = directory.first { $0.callsign == "K0EPI-7" }
        XCTAssertEqual(human?.roleBadges, ["Keyboarder"],
                       "The station typing at the BBS is the keyboarder")
    }

    func testStationDirectoryRollsUpSenders() {
        let base = Date(timeIntervalSince1970: 1_700_007_000)
        let packets = [
            makePacket(timestamp: base, from: "DRLNOD", to: "NODES", frameType: .ui),
            makePacket(timestamp: base.addingTimeInterval(60), from: "DRLNOD", to: "ID", frameType: .ui),
            makePacket(timestamp: base.addingTimeInterval(120), from: "W1AAA", to: "BEACON", frameType: .ui)
        ]
        let roles = StationRoleInference.inferRoles(packets: packets, identityMode: .ssid)
        let directory = StationDirectoryBuilder.build(packets: packets, roles: roles, identityMode: .ssid)

        XCTAssertEqual(directory.map(\.callsign), ["W1AAA", "DRLNOD"], "Sorted by last heard, newest first")
        let node = directory.first { $0.callsign == "DRLNOD" }
        XCTAssertEqual(node?.frameCount, 2)
        XCTAssertEqual(node?.roleBadges.first, "Node")
        XCTAssertEqual(node?.firstHeard, base)
        XCTAssertEqual(node?.lastHeard, base.addingTimeInterval(60))
        let beaconer = directory.first { $0.callsign == "W1AAA" }
        XCTAssertEqual(beaconer?.roleBadges, ["Beacon"], "No inferred role reads as beacon-only")
    }
}
