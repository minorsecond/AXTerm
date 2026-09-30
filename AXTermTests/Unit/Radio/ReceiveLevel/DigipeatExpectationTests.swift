//
//  DigipeatExpectationTests.swift
//  AXTermTests
//
//  Which digipeaters usually repeat us is learned from our own frames, and
//  three frames in a row repeated by nobody, after they used to be, is a
//  finding.
//

import XCTest
@testable import AXTerm

final class DigipeatExpectationTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// Beacons every ten minutes; `echoes[i]` repeats beacon i.
    private func history(_ echoes: [[String]]) -> DigipeatExpectation {
        var d = DigipeatExpectation()
        for (i, digis) in echoes.enumerated() {
            let sent = at(Double(i) * 10)
            d.noteSent(at: sent)
            for (j, digi) in digis.enumerated() {
                d.noteEcho(from: digi, at: sent.addingTimeInterval(1.5 + Double(j)))
            }
        }
        return d
    }

    private var late: Date { at(1_000) }

    func testLearnsAndFlagsThreeMisses() throws {
        let d = history(Array(repeating: ["WA0DE-3"], count: 9) + [["WA0DE-3", "K0XYZ-1"]] + [[], [], []])
        let f = try XCTUnwrap(d.assess(now: late))
        XCTAssertEqual(f.misses, 3)
        XCTAssertEqual(f.earlierFrames, 10)
        XCTAssertEqual(f.usual.first?.call, "WA0DE-3")
        XCTAssertEqual(f.usual.first?.repeated, 10)
        XCTAssertFalse(f.usual.contains { $0.call == "K0XYZ-1" }, "one repeat in ten isn't usual")
        XCTAssertEqual(f.lastEchoAt, at(90))
    }

    func testTwoMissesAreOrdinary() {
        let d = history(Array(repeating: ["WA0DE-3"], count: 10) + [[], []])
        XCTAssertNil(d.assess(now: late))
    }

    func testNotEnoughHistory() {
        let d = history([["WA0DE-3"], ["WA0DE-3"], ["WA0DE-3"], ["WA0DE-3"], [], [], []])
        XCTAssertNil(d.assess(now: late))
    }

    func testNoUsualDigipeaterNoFinding() {
        // Repeated now and then by different stations: nobody is expected.
        let d = history([["A"], [], ["B"], [], ["C"], [], [], [], []])
        XCTAssertNil(d.assess(now: late))
    }

    func testAnEchoFromAnyoneEndsTheRun() {
        let d = history(Array(repeating: ["WA0DE-3"], count: 8) + [[], ["K0XYZ-1"], [], []])
        XCTAssertNil(d.assess(now: late))
    }

    func testAFrameStillInsideItsEchoWindowIsNotAMiss() {
        let d = history(Array(repeating: ["WA0DE-3"], count: 8) + [[], [], []])
        // The last frame went out at 100 min; 10 s later its repeats could still come.
        XCTAssertNil(d.assess(now: at(100).addingTimeInterval(10)))
        XCTAssertNotNil(d.assess(now: at(100).addingTimeInterval(DigipeatExpectation.echoWindow + 1)))
    }

    func testEchoesOutsideTheWindowAreNotCredited() {
        var d = DigipeatExpectation()
        d.noteSent(at: t0)
        XCTAssertFalse(d.noteEcho(from: "WA0DE-3", at: t0.addingTimeInterval(45)))
        XCTAssertFalse(d.noteEcho(from: "WA0DE-3", at: t0.addingTimeInterval(-1)))
        XCTAssertTrue(d.noteEcho(from: "wa0de-3", at: t0.addingTimeInterval(2)))
        XCTAssertFalse(d.noteEcho(from: "WA0DE-3", at: t0.addingTimeInterval(3)), "same digipeater twice counts once")
        XCTAssertEqual(d.sent.first?.echoedBy, ["WA0DE-3"])
    }

    func testHistoryIsBounded() {
        var d = DigipeatExpectation()
        for i in 0..<50 { d.noteSent(at: at(Double(i))) }
        XCTAssertEqual(d.sent.count, DigipeatExpectation.history)
    }

    func testRoundTripsAndToleratesJunk() throws {
        let d = history([["A"], ["B", "A"]])
        let data = try JSONEncoder().encode(d)
        XCTAssertEqual(try JSONDecoder().decode(DigipeatExpectation.self, from: data), d)
        let junk = Data(#"{"sent": 7}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(DigipeatExpectation.self, from: junk), DigipeatExpectation())
    }

    func testFindingWords() throws {
        let d = history(Array(repeating: ["WA0DE-3"], count: 9) + [[]] + [[], [], []])
        let f = try XCTUnwrap(d.assess(now: late))
        let finding = ReceiveLevelFinding.digipeats(f, radioName: "TNC4 Mobilinkd", time: { _ in "10:05" })
        XCTAssertEqual(finding.message,
                       "None of your last 4 frames on TNC4 Mobilinkd were heard repeated, though WA0DE-3 repeated 9 of the 9 before. "
                       + "Check the radio's volume, squelch and antenna.")
        XCTAssertEqual(finding.retune, .calibrate)
        XCTAssertTrue(finding.evidence.contains("This can't tell a receive problem from a transmit problem."))
    }
}
