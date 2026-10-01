//
//  HalfDuplexChannelTests.swift
//  AXTermTests
//
//  The simulated channel behind ConnectedModeStressTests does what it says:
//  airtime, half duplex, carrier sense with p-persistence, collisions, the
//  transmitter hang, digipeating, fades and determinism. If the channel is
//  wrong, every stress figure built on it is wrong too.
//

import XCTest
@testable import AXTerm

@MainActor
final class HalfDuplexChannelTests: XCTestCase {

    private let callA = AX25Address(call: "K0AAA", ssid: 1)
    private let callB = AX25Address(call: "K0BBB", ssid: 2)
    private let callC = AX25Address(call: "K0CCC", ssid: 3)
    private let callD = AX25Address(call: "DIGI", ssid: 1)

    private struct Heard {
        let at: TimeInterval
        let bytes: Data
    }

    /// A UI frame from `from` to `to`, `payload` bytes long.
    private func frame(from: AX25Address, to: AX25Address, via: [AX25Address] = [],
                       payload: Int = 100, fill: UInt8 = 0x00) -> Data {
        OutboundFrame(destination: to, source: from, path: DigiPath(via),
                      payload: Data(repeating: fill, count: payload)).encodeAX25()
    }

    private func radio(txDelay: TimeInterval = 0.3, hang: TimeInterval = 0,
                       persistence: Int = 255) -> SimRadioConfig {
        var r = SimRadioConfig()
        r.txDelay = txDelay
        r.txTail = 0.03
        r.hang = hang
        r.persistence = persistence
        r.decodeLatency = 0
        return r
    }

    private func listen(_ node: SimNode, _ channel: HalfDuplexChannel, into log: @escaping (Heard) -> Void) {
        node.deliver = { bytes in log(Heard(at: channel.clock.currentTime, bytes: bytes)) }
    }

    // MARK: Airtime

    func testFrameBitsCountStuffingFCSAndFlag() {
        XCTAssertEqual(HalfDuplexChannel.frameBits(Data(repeating: 0x00, count: 10)), 80 + 24)
        // 0xFF is eight ones: one stuffed bit after every five ones in a row.
        XCTAssertEqual(HalfDuplexChannel.frameBits(Data([0xFF])), 8 + 1 + 24)
        XCTAssertEqual(HalfDuplexChannel.frameBits(Data(repeating: 0xFF, count: 5)), 40 + 8 + 24)
    }

    func testAFrameArrivesAfterTXDelayAndAirtime() {
        let clock = AX25VirtualClock()
        let channel = HalfDuplexChannel(clock: clock, seed: 1)
        let a = channel.addNode(name: "A", call: callA, radio: radio())
        let b = channel.addNode(name: "B", call: callB, radio: radio())
        var heard: [Heard] = []
        listen(b, channel) { heard.append($0) }

        let bytes = frame(from: callA, to: callB)
        channel.send(from: a.index, bytes: bytes, tag: 1)
        clock.advance(by: 10)

        let airtime = Double(HalfDuplexChannel.frameBits(bytes)) / 1200
        XCTAssertEqual(heard.count, 1)
        XCTAssertEqual(heard.first?.at ?? 0, 0.3 + airtime, accuracy: 1e-9)
        XCTAssertEqual(heard.first?.bytes, bytes)
        XCTAssertEqual(channel.stats.airtime[a.index] ?? 0, 0.3 + airtime + 0.03, accuracy: 1e-9)

        // Nine times the bit rate, a ninth of the airtime.
        let fast = HalfDuplexChannel(clock: AX25VirtualClock(), seed: 1)
        XCTAssertEqual(fast.airtime(bytes, at: 9600) * 8, channel.airtime(bytes, at: 1200), accuracy: 1e-9)
    }

    func testFramesQueuedTogetherGoOutInOneTransmission() {
        let clock = AX25VirtualClock()
        let channel = HalfDuplexChannel(clock: clock, seed: 1)
        let a = channel.addNode(name: "A", call: callA, radio: radio())
        let b = channel.addNode(name: "B", call: callB, radio: radio())
        var heard: [Heard] = []
        listen(b, channel) { heard.append($0) }

        let first = frame(from: callA, to: callB, payload: 50)
        let second = frame(from: callA, to: callB, payload: 60)
        channel.send(from: a.index, bytes: first, tag: 1)
        clock.advance(by: 0.5)
        // Handed over while the first frame is still on the air: same key-up.
        channel.send(from: a.index, bytes: second, tag: 2)
        clock.advance(by: 10)

        XCTAssertEqual(channel.stats.transmissions, 1)
        XCTAssertEqual(heard.count, 2)
        let t1 = 0.3 + channel.airtime(first, at: 1200)
        XCTAssertEqual(heard[1].at, t1 + channel.airtime(second, at: 1200), accuracy: 1e-9)
    }

    // MARK: Half duplex

    func testAStationHearsNothingWhileItTransmits() {
        let clock = AX25VirtualClock()
        let channel = HalfDuplexChannel(clock: clock, seed: 1)
        channel.collisionsEnabled = false
        let a = channel.addNode(name: "A", call: callA, radio: radio())
        let b = channel.addNode(name: "B", call: callB, radio: radio())
        // A cannot hear B and B cannot hear A's carrier, so B keys up anyway.
        channel.setLink(from: a.index, to: b.index, SimLinkConfig(audible: false))
        var heardByA: [Heard] = []
        listen(a, channel) { heardByA.append($0) }
        var outcomes: [SimReception] = []
        channel.onReception = { _, _, _, outcome in outcomes.append(outcome) }

        channel.send(from: a.index, bytes: frame(from: callA, to: callB, payload: 200), tag: 1)
        clock.advance(by: 0.2)
        channel.send(from: b.index, bytes: frame(from: callB, to: callA, payload: 20), tag: 2)
        clock.advance(by: 10)

        XCTAssertTrue(heardByA.isEmpty)
        XCTAssertEqual(outcomes, [.deaf])
        XCTAssertEqual(channel.stats.deafLosses, 1)
    }

    // MARK: Carrier sense

    func testATNCWaitsForTheChannelToClear() {
        let clock = AX25VirtualClock()
        let channel = HalfDuplexChannel(clock: clock, seed: 1)
        let a = channel.addNode(name: "A", call: callA, radio: radio())
        let b = channel.addNode(name: "B", call: callB, radio: radio())
        var heardByA: [Heard] = []
        listen(a, channel) { heardByA.append($0) }

        let long = frame(from: callA, to: callB, payload: 200)
        channel.send(from: a.index, bytes: long, tag: 1)
        clock.advance(by: 0.5)
        let reply = frame(from: callB, to: callA, payload: 10)
        channel.send(from: b.index, bytes: reply, tag: 2)
        clock.advance(by: 10)

        XCTAssertEqual(channel.stats.busyDefers, 1)
        XCTAssertEqual(channel.stats.collisions, 0)
        // Persistence 255 keys the moment A's tail ends.
        let aTailEnd = 0.3 + channel.airtime(long, at: 1200) + 0.03
        XCTAssertEqual(heardByA.first?.at ?? 0, aTailEnd + 0.3 + channel.airtime(reply, at: 1200), accuracy: 1e-9)
    }

    func testPersistenceDefersAboutAsOftenAsItShould() {
        // With persistence 63 a TNC keys in a given slot with chance 64/256,
        // so it waits a mean of three slots before keying.
        let clock = AX25VirtualClock()
        let channel = HalfDuplexChannel(clock: clock, seed: 7)
        let a = channel.addNode(name: "A", call: callA, radio: radio(persistence: 63))
        _ = channel.addNode(name: "B", call: callB, radio: radio())
        let trials = 2000
        for i in 0..<trials {
            channel.send(from: a.index, bytes: frame(from: callA, to: callB, payload: 10), tag: i)
            clock.advance(by: 30)
        }
        let mean = Double(channel.stats.persistenceDefers) / Double(trials)
        XCTAssertEqual(mean, 3.0, accuracy: 0.3)
    }

    func testTwoTNCsReleasedAtOnceCanCollide() {
        // Both wait for C to finish, then both decide in the same slot. With
        // persistence 255 they always key together and collide at C.
        let clock = AX25VirtualClock()
        let channel = HalfDuplexChannel(clock: clock, seed: 3)
        let a = channel.addNode(name: "A", call: callA, radio: radio())
        let b = channel.addNode(name: "B", call: callB, radio: radio())
        let c = channel.addNode(name: "C", call: callC, radio: radio())
        var heardByC: [Heard] = []
        listen(c, channel) { heardByC.append($0) }

        channel.send(from: c.index, bytes: frame(from: callC, to: callA, payload: 100), tag: 1)
        clock.advance(by: 0.4)
        channel.send(from: a.index, bytes: frame(from: callA, to: callC), tag: 2)
        channel.send(from: b.index, bytes: frame(from: callB, to: callC), tag: 3)
        clock.advance(by: 10)

        XCTAssertTrue(heardByC.isEmpty)
        XCTAssertEqual(channel.stats.collisions, 2)
    }

    func testHiddenStationsCollideAtTheStationBetweenThem() {
        let clock = AX25VirtualClock()
        let channel = HalfDuplexChannel(clock: clock, seed: 1)
        let a = channel.addNode(name: "A", call: callA, radio: radio())
        let b = channel.addNode(name: "B", call: callB, radio: radio())
        let c = channel.addNode(name: "C", call: callC, radio: radio())
        channel.setLinks(between: a.index, and: b.index, SimLinkConfig(audible: false))
        var heardByC: [Heard] = []
        listen(c, channel) { heardByC.append($0) }

        channel.send(from: a.index, bytes: frame(from: callA, to: callC), tag: 1)
        clock.advance(by: 0.5)
        channel.send(from: b.index, bytes: frame(from: callB, to: callC), tag: 2)
        clock.advance(by: 10)

        XCTAssertTrue(heardByC.isEmpty)
        XCTAssertEqual(channel.stats.collisions, 2)
        XCTAssertEqual(channel.stats.busyDefers, 0, "neither could hear the other")
    }

    // MARK: Transmitter hang

    /// The live finding: the 705 stays keyed 0.7 s after its frame with an
    /// unmodulated carrier. The far TNC does not sense it and answers at
    /// once; a TX delay shorter than the hang loses the reply, a longer one
    /// saves it.
    func testAReplyInsideThePeersHangIsLostUnlessTheTXDelayOutlastsIt() {
        for (txDelay, expectHeard) in [(0.3, false), (0.8, true)] {
            let clock = AX25VirtualClock()
            let channel = HalfDuplexChannel(clock: clock, seed: 1)
            let a = channel.addNode(name: "A", call: callA, radio: radio(hang: 0.7))
            let b = channel.addNode(name: "B", call: callB, radio: radio(txDelay: txDelay))
            var heardByA: [Heard] = []
            listen(a, channel) { heardByA.append($0) }
            listen(b, channel) { bytes in
                channel.send(from: b.index, bytes: self.frame(from: self.callB, to: self.callA, payload: 10), tag: 2)
                _ = bytes
            }
            channel.send(from: a.index, bytes: frame(from: callA, to: callB), tag: 1)
            clock.advance(by: 10)
            XCTAssertEqual(!heardByA.isEmpty, expectHeard, "TX delay \(txDelay)")
            // B waited out A's tail, which is sensed, but not its hang.
            let aTx = channel.transmissions[0]
            XCTAssertEqual(channel.transmissions.count, 2)
            XCTAssertEqual(channel.transmissions[1].start, aTx.tailEnd, accuracy: 1e-9,
                           "the hang is not sensed")
            XCTAssertLessThan(channel.transmissions[1].start, aTx.hangEnd)
        }
    }

    // MARK: Digipeating

    func testADigipeaterRepeatsWithTheHBitSet() {
        let clock = AX25VirtualClock()
        let channel = HalfDuplexChannel(clock: clock, seed: 1)
        let a = channel.addNode(name: "A", call: callA, radio: radio())
        let b = channel.addNode(name: "B", call: callB, radio: radio())
        let d = channel.addNode(name: "D", call: callD, radio: radio(), isDigipeater: true)
        channel.setLinks(between: a.index, and: b.index, SimLinkConfig(audible: false))
        _ = d
        var heardByB: [Heard] = []
        listen(b, channel) { heardByB.append($0) }

        channel.send(from: a.index, bytes: frame(from: callA, to: callB, via: [callD]), tag: 1)
        clock.advance(by: 10)

        XCTAssertEqual(heardByB.count, 1)
        let decoded = AX25.decodeFrame(ax25: heardByB[0].bytes)
        XCTAssertEqual(decoded?.via.first?.repeated, true)
        XCTAssertEqual(channel.stats.intended[.delivered], 2, "the digipeater, then B")
    }

    // MARK: Impairments

    func testFadesLoseAboutTheirShareOfFrames() {
        let clock = AX25VirtualClock()
        let channel = HalfDuplexChannel(clock: clock, seed: 11)
        let a = channel.addNode(name: "A", call: callA, radio: radio())
        let b = channel.addNode(name: "B", call: callB, radio: radio())
        channel.setLinks(between: a.index, and: b.index,
                         SimLinkConfig(fade: SimFadeModel(meanClear: 30, meanFade: 10)))
        var heard = 0
        b.deliver = { _ in heard += 1 }
        let trials = 3000
        for i in 0..<trials {
            channel.send(from: a.index, bytes: frame(from: callA, to: callB, payload: 10), tag: i)
            clock.advance(by: 2)
        }
        let lost = Double(trials - heard) / Double(trials)
        XCTAssertEqual(lost, 0.25, accuracy: 0.07, "fades cover a quarter of the time")
    }

    func testRandomLossAndUSBDropRates() {
        let clock = AX25VirtualClock()
        let channel = HalfDuplexChannel(clock: clock, seed: 5)
        var lossy = radio()
        lossy.hostDropRate = 0.1
        let a = channel.addNode(name: "A", call: callA, radio: lossy)
        let b = channel.addNode(name: "B", call: callB, radio: radio())
        channel.setLinks(between: a.index, and: b.index, SimLinkConfig(lossRate: 0.2))
        var heard = 0
        b.deliver = { _ in heard += 1 }
        let trials = 5000
        for i in 0..<trials {
            channel.send(from: a.index, bytes: frame(from: callA, to: callB, payload: 10), tag: i)
            clock.advance(by: 2)
        }
        XCTAssertEqual(Double(channel.stats.hostDrops) / Double(trials), 0.1, accuracy: 0.02)
        XCTAssertEqual(Double(heard) / Double(trials), 0.9 * 0.8, accuracy: 0.03)
    }

    // MARK: Determinism

    func testTheSameSeedReplaysTheSameRun() {
        func run(seed: UInt64) -> [String] {
            let clock = AX25VirtualClock()
            let channel = HalfDuplexChannel(clock: clock, seed: seed)
            let a = channel.addNode(name: "A", call: callA, radio: radio(persistence: 63))
            let b = channel.addNode(name: "B", call: callB, radio: radio(persistence: 63))
            channel.setLinks(between: a.index, and: b.index,
                             SimLinkConfig(lossRate: 0.2, duplicateRate: 0.1,
                                           fade: SimFadeModel(meanClear: 20, meanFade: 3)))
            for i in 0..<200 {
                channel.send(from: i % 2 == 0 ? a.index : b.index,
                             bytes: frame(from: i % 2 == 0 ? callA : callB, to: i % 2 == 0 ? callB : callA,
                                          payload: 10 + i % 50), tag: i)
                clock.advance(by: 0.4)
            }
            clock.advance(by: 30)
            return channel.trace
        }
        XCTAssertEqual(run(seed: 42), run(seed: 42))
        XCTAssertNotEqual(run(seed: 42), run(seed: 43))
    }
}
