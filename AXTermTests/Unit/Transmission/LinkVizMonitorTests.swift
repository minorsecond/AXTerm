//
//  LinkVizMonitorTests.swift
//  AXTermTests
//
//  The link visualization pipeline aggregates raw AX25SessionManager events
//  into bounded per-peer histories (RTT, window, throughput, deliveries).
//  These tests pin the aggregation math the charts depend on: goodput vs raw
//  accounting, second-aligned throughput buckets, loss-event markers, and the
//  memory caps that keep a day-long session from growing without bound.
//

import XCTest
@testable import AXTerm

@MainActor
final class LinkVizMonitorTests: XCTestCase {

    private func snapshot(
        peer: String = "W0ARP-10",
        context: String = "inbound-I",
        vs: Int = 3, va: Int = 1, vr: Int = 5,
        outstanding: Int = 2, windowSize: Int = 2,
        sendBufferSeq: [Int] = [1, 2],
        rto: Double = 4.0, srtt: Double? = 1.5, rttvar: Double = 0.4,
        date: Date = Date(timeIntervalSince1970: 1_000)
    ) -> LinkWindowSnapshot {
        LinkWindowSnapshot(
            peer: peer, context: context, vs: vs, va: va, vr: vr,
            outstanding: outstanding, windowSize: windowSize, retryCount: 0,
            sendBufferSeq: sendBufferSeq, rto: rto, srtt: srtt, rttvar: rttvar,
            date: date)
    }

    // MARK: - Monitor routing

    func testMonitorRoutesEventsToPerPeerAggregatesCaseInsensitively() async {
        let monitor = LinkVizMonitor()
        monitor.ingest(.inboundIFrame(peer: "w0arp-10", ns: 0, bytes: 100))
        monitor.ingest(.delivered(peer: "W0ARP-10", bytes: 100))
        monitor.ingest(.inboundIFrame(peer: "K0NTS-10", ns: 0, bytes: 50))

        XCTAssertEqual(monitor.sessions.count, 2, "mixed-case peer must not fork a second aggregate")
        XCTAssertEqual(monitor.sessions["W0ARP-10"]?.totalRawBytes, 100)
        XCTAssertEqual(monitor.sessions["W0ARP-10"]?.totalDeliveredBytes, 100)
        XCTAssertEqual(monitor.sessions["K0NTS-10"]?.totalRawBytes, 50)
    }

    func testMostRecentlyActivePicksTheLatestLink() async {
        let monitor = LinkVizMonitor()
        monitor.viz(for: "OLD-1").apply(.delivered(peer: "OLD-1", bytes: 1),
                                        now: Date(timeIntervalSince1970: 100))
        monitor.viz(for: "NEW-1").apply(.delivered(peer: "NEW-1", bytes: 1),
                                        now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(monitor.mostRecentlyActive?.peer, "NEW-1")
    }

    // MARK: - Goodput vs raw (retransmit overhead)

    /// Every inbound I-frame counts as raw channel bytes; only in-order
    /// deliveries count as goodput. A retransmitted copy therefore widens the
    /// gap — that gap IS the overhead the console header reports.
    func testReceiveOverheadReflectsRetransmittedCopies() async {
        let viz = LinkSessionViz(peer: "W0ARP-10")
        let t = Date(timeIntervalSince1970: 5_000)

        viz.apply(.inboundIFrame(peer: "W0ARP-10", ns: 0, bytes: 128), now: t)
        viz.apply(.delivered(peer: "W0ARP-10", bytes: 128), now: t)
        // The same frame heard again (peer missed our ACK): raw, not goodput.
        viz.apply(.inboundIFrame(peer: "W0ARP-10", ns: 0, bytes: 128), now: t)

        XCTAssertEqual(viz.totalRawBytes, 256)
        XCTAssertEqual(viz.totalDeliveredBytes, 128)
        XCTAssertEqual(viz.receiveOverheadFraction, 0.5, accuracy: 0.0001)
    }

    func testOverheadIsZeroBeforeAnyTraffic() async {
        XCTAssertEqual(LinkSessionViz(peer: "X").receiveOverheadFraction, 0)
    }

    // MARK: - Throughput bucketing

    func testThroughputBucketsAreSecondAlignedAndMerged() async {
        let viz = LinkSessionViz(peer: "W0ARP-10")
        let base = Date(timeIntervalSince1970: 1_000)

        viz.apply(.inboundIFrame(peer: "W0ARP-10", ns: 0, bytes: 100), now: base)
        viz.apply(.delivered(peer: "W0ARP-10", bytes: 100), now: base.addingTimeInterval(0.4))
        viz.apply(.inboundIFrame(peer: "W0ARP-10", ns: 1, bytes: 50), now: base.addingTimeInterval(1.2))

        XCTAssertEqual(viz.throughput.count, 2, "two distinct wall-clock seconds → two buckets")
        XCTAssertEqual(viz.throughput[0].date, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(viz.throughput[0].rawBytes, 100)
        XCTAssertEqual(viz.throughput[0].deliveredBytes, 100, "same-second raw and goodput share a bucket")
        XCTAssertEqual(viz.throughput[1].rawBytes, 50)
        XCTAssertEqual(viz.throughput[1].deliveredBytes, 0)
    }

    // MARK: - Loss markers on the window history

    func testT1TimeoutSnapshotAndRejMarkLossEvents() async {
        let viz = LinkSessionViz(peer: "W0ARP-10")
        viz.apply(.snapshot(snapshot(context: "inbound-I")))
        viz.apply(.snapshot(snapshot(context: "T1-timeout")))
        viz.apply(.rejSent(peer: "W0ARP-10", nr: 4))

        XCTAssertEqual(viz.t1Count, 1)
        XCTAssertEqual(viz.rejCount, 1)
        let markers = viz.windowHistory.compactMap { $0.lossEvent }
        XCTAssertEqual(markers, ["t1", "rej"],
                       "ordinary snapshots carry no marker; T1 and REJ each add one")
    }

    /// The REJ marker needs a prior snapshot for its y-position; without one
    /// it still counts but cannot plot.
    func testRejBeforeAnySnapshotCountsButAddsNoWindowSample() async {
        let viz = LinkSessionViz(peer: "W0ARP-10")
        viz.apply(.rejSent(peer: "W0ARP-10", nr: 0))
        XCTAssertEqual(viz.rejCount, 1)
        XCTAssertTrue(viz.windowHistory.isEmpty)
    }

    // MARK: - RTT dedup and caps

    func testUnchangedRttSamplesAreDeduplicated() async {
        let viz = LinkSessionViz(peer: "W0ARP-10")
        viz.apply(.snapshot(snapshot(srtt: 1.5)))
        viz.apply(.snapshot(snapshot(srtt: 1.5)))
        viz.apply(.snapshot(snapshot(srtt: 2.0)))
        XCTAssertEqual(viz.rttHistory.map { $0.srtt }, [1.5, 2.0])
    }

    func testSnapshotWithoutSrttAddsNoRttSample() async {
        let viz = LinkSessionViz(peer: "W0ARP-10")
        viz.apply(.snapshot(snapshot(srtt: nil)))
        XCTAssertTrue(viz.rttHistory.isEmpty)
    }

    func testHistoriesStayBounded() async {
        let viz = LinkSessionViz(peer: "W0ARP-10")
        let base = Date(timeIntervalSince1970: 0)
        for i in 0..<2_000 {
            let now = base.addingTimeInterval(Double(i))
            viz.apply(.snapshot(snapshot(srtt: Double(i), date: now)), now: now)
            viz.apply(.delivered(peer: "W0ARP-10", bytes: 128), now: now)
        }
        XCTAssertLessThanOrEqual(viz.rttHistory.count, 400)
        XCTAssertLessThanOrEqual(viz.windowHistory.count, 800)
        XCTAssertLessThanOrEqual(viz.deliveries.count, 900)
        XCTAssertLessThanOrEqual(viz.throughput.count, 900)
        XCTAssertEqual(viz.rttHistory.last?.srtt, 1_999, "caps must drop the OLDEST samples")
    }

    // MARK: - Per-transfer reset

    func testResetTransferCountersKeepsLinkHistory() async {
        let viz = LinkSessionViz(peer: "W0ARP-10")
        viz.apply(.snapshot(snapshot()))
        viz.apply(.inboundIFrame(peer: "W0ARP-10", ns: 0, bytes: 100))
        viz.apply(.delivered(peer: "W0ARP-10", bytes: 100))
        viz.apply(.rejSent(peer: "W0ARP-10", nr: 1))
        viz.apply(.retransmit(peer: "W0ARP-10", count: 2))

        viz.resetTransferCounters()

        XCTAssertEqual(viz.totalRawBytes, 0)
        XCTAssertEqual(viz.totalDeliveredBytes, 0)
        XCTAssertEqual(viz.rejCount, 0)
        XCTAssertEqual(viz.retransmitCount, 0)
        XCTAssertTrue(viz.deliveries.isEmpty)
        XCTAssertTrue(viz.throughput.isEmpty)
        XCTAssertFalse(viz.rttHistory.isEmpty, "RTT continuity survives a new transfer")
        XCTAssertFalse(viz.windowHistory.isEmpty, "window continuity survives a new transfer")
    }

    // MARK: - Channel airtime

    func testAirtimeEstimateMatchesFrameSizeAtBaudRate() async {
        let monitor = ChannelActivityMonitor()
        monitor.baudRate = 1200
        monitor.record(callsign: "K0EPI-7", frameBytes: 144, isTransmit: true,
                       date: Date(timeIntervalSince1970: 100))
        // (144 + 6 HDLC overhead) * 8 bits * 1.05 stuffing / 1200 baud = 1.05 s
        XCTAssertEqual(monitor.samples.first?.airtimeSeconds ?? 0, 1.05, accuracy: 0.0001)
        XCTAssertEqual(monitor.samples.first?.callsign, "K0EPI-7")
    }

    func testLanesOrderBusiestFirstAndUtilizationIsBounded() async {
        let monitor = ChannelActivityMonitor()
        monitor.baudRate = 1200
        let base = Date(timeIntervalSince1970: 10_000)
        monitor.record(callsign: "quiet-1", frameBytes: 20, isTransmit: false, date: base)
        monitor.record(callsign: "BUSY-1", frameBytes: 250, isTransmit: false, date: base.addingTimeInterval(5))
        monitor.record(callsign: "BUSY-1", frameBytes: 250, isTransmit: false, date: base.addingTimeInterval(10))

        XCTAssertEqual(monitor.lanes.map { $0.callsign }, ["BUSY-1", "QUIET-1"])
        let util = monitor.utilization(now: base.addingTimeInterval(10))
        XCTAssertGreaterThan(util, 0)
        XCTAssertLessThanOrEqual(util, 1)
    }

    func testSamplesOutsideTheWindowAreTrimmed() async {
        let monitor = ChannelActivityMonitor()
        let base = Date(timeIntervalSince1970: 50_000)
        monitor.record(callsign: "OLD-1", frameBytes: 50, isTransmit: false, date: base)
        monitor.record(callsign: "NEW-1", frameBytes: 50, isTransmit: false,
                       date: base.addingTimeInterval(ChannelActivityMonitor.window + 60))
        XCTAssertEqual(monitor.samples.map { $0.callsign }, ["NEW-1"])
    }
}
