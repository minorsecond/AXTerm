import XCTest
@testable import AXTerm

/// Callsigns here are from this receiver's own station list.
final class HeardStationMapTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func station(_ call: String, heard: Int = 10,
                         agoSeconds: TimeInterval? = 60,
                         via: [String] = []) -> Station {
        Station(call: call,
                lastHeard: agoSeconds.map { now.addingTimeInterval(-$0) },
                heardCount: heard, lastVia: via)
    }

    private func record(_ call: String, grid: String? = "DM79ql",
                        latitude: Double? = nil, longitude: Double? = nil,
                        source: String = "HamDB") -> CallsignRecord {
        CallsignRecord(callsign: call, name: "Alex Example", gridSquare: grid,
                       latitude: latitude, longitude: longitude,
                       locality: "Parker", source: source, fetchedAt: now)
    }

    // MARK: - Placement

    /// Exact coordinates beat a grid square. A grid is a box up to 8 km
    /// across, and every station in it collapses onto one identical
    /// centre point — which is exactly why co-located gateways could not
    /// be told apart at any zoom level.
    func testExactCoordinatesBeatAGridSquare() throws {
        let entries = HeardStationMap.entries(
            stations: [station("W0ARP-10")],
            directory: ["W0ARP": record("W0ARP", grid: "DM79ql",
                                        latitude: 39.4918279, longitude: -104.6398437)],
            gatewayGrids: ["W0ARP-10": "DM79QL"])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertTrue(entry.isExactPosition)
        XCTAssertEqual(entry.position?.latitude ?? 0, 39.4918279, accuracy: 0.000001)
        XCTAssertTrue(entry.positionSource?.contains("licence address") == true,
                      entry.positionSource ?? "")
        // The gateway's own grid is still shown as the label.
        XCTAssertEqual(entry.gridSquare, "DM79QL")
    }

    /// Two gateways sharing a grid square must end up at *different*
    /// coordinates once their licence addresses are known — otherwise no
    /// amount of zooming separates them.
    func testCoLocatedGatewaysSeparateOnceExactPositionsAreKnown() {
        let entries = HeardStationMap.entries(
            stations: [station("W0ARP-10"), station("N0HI-10")],
            directory: [
                "W0ARP": record("W0ARP", latitude: 39.4918, longitude: -104.6398),
                "N0HI": record("N0HI", latitude: 39.5200, longitude: -104.7100),
            ],
            gatewayGrids: ["W0ARP-10": "DM79QL", "N0HI-10": "DM79QL"])
        XCTAssertEqual(HeardStationMap.clusters(entries).count, 2)
    }

    /// With no exact coordinate anywhere, the grid centre is still used
    /// — a coarse position beats none.
    func testGridSquareIsUsedWhenNoExactCoordinateExists() throws {
        let entries = HeardStationMap.entries(
            stations: [station("W0ARP-10")],
            directory: [:],
            gatewayGrids: ["W0ARP-10": "DM79QL"])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertFalse(entry.isExactPosition)
        XCTAssertTrue(entry.positionSource?.contains("grid square") == true,
                      entry.positionSource ?? "")
    }

    /// The directory is keyed by base callsign, so a heard SSID still
    /// resolves through its licensee.
    func testDirectoryResolvesAnSSIDViaTheBaseCallsign() throws {
        let entries = HeardStationMap.entries(
            stations: [station("KB5YZB-7")],
            directory: ["KB5YZB": record("KB5YZB")],
            gatewayGrids: [:])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertTrue(entry.isPlaced)
        XCTAssertTrue(entry.positionSource?.hasPrefix("HamDB") == true,
                      entry.positionSource ?? "")
        XCTAssertEqual(entry.name, "Alex Example")
    }

    /// A station nobody can locate is kept, not hidden. It is often the
    /// most interesting row in the table.
    func testUnplaceableStationsAreKept() throws {
        let entries = HeardStationMap.entries(
            stations: [station("N0BN", heard: 400)],
            directory: [:], gatewayGrids: [:])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertFalse(entry.isPlaced)
        XCTAssertEqual(entry.heardCount, 400)
        XCTAssertNil(entry.positionSource)
    }

    /// A record with no usable position does not count as placed.
    func testARecordWithoutAPositionDoesNotPlaceTheStation() throws {
        let entries = HeardStationMap.entries(
            stations: [station("N0BN")],
            directory: ["N0BN": record("N0BN", grid: nil)],
            gatewayGrids: [:])
        XCTAssertFalse(try XCTUnwrap(entries.first).isPlaced)
    }

    // MARK: - Ordering

    func testMostRecentlyHeardComesFirst() {
        let entries = HeardStationMap.entries(
            stations: [
                station("OLD", agoSeconds: 7200),
                station("NEW", agoSeconds: 30),
                station("MID", agoSeconds: 600),
            ],
            directory: [:], gatewayGrids: [:])
        XCTAssertEqual(entries.map(\.callsign), ["NEW", "MID", "OLD"])
    }

    func testNeverHeardStationsSinkToTheBottom() {
        let entries = HeardStationMap.entries(
            stations: [station("SILENT", agoSeconds: nil), station("HEARD")],
            directory: [:], gatewayGrids: [:])
        XCTAssertEqual(entries.last?.callsign, "SILENT")
    }

    // MARK: - Signal

    /// For a heard station, recency is the only thing the receiver
    /// actually measured.
    func testRecencyDrivesTheSignal() {
        let active = HeardStationMap.Entry(
            callsign: "A", heardCount: 1, lastHeard: now.addingTimeInterval(-60), lastVia: [])
        let hours = HeardStationMap.Entry(
            callsign: "B", heardCount: 1, lastHeard: now.addingTimeInterval(-7200), lastVia: [])
        let old = HeardStationMap.Entry(
            callsign: "C", heardCount: 1, lastHeard: now.addingTimeInterval(-100_000), lastVia: [])
        let never = HeardStationMap.Entry(
            callsign: "D", heardCount: 0, lastHeard: nil, lastVia: [])

        XCTAssertEqual(HeardStationMap.signal(for: active, now: now), .good)
        XCTAssertEqual(HeardStationMap.signal(for: hours, now: now), .fair)
        XCTAssertEqual(HeardStationMap.signal(for: old, now: now), .poor)
        XCTAssertEqual(HeardStationMap.signal(for: never, now: now), .unknown)
        XCTAssertTrue(HeardStationMap.isStale(old, now: now))
        XCTAssertFalse(HeardStationMap.isStale(active, now: now))
    }

    // MARK: - Scope

    /// Only placed stations reach the map; inventing a position for the
    /// rest would be worse than the gap.
    func testOnlyPlacedEntriesReachTheScope() {
        let entries = HeardStationMap.entries(
            stations: [station("W0ARP-10"), station("N0BN")],
            directory: [:],
            gatewayGrids: ["W0ARP-10": "DM79QL"])
        let scope = HeardStationMap.scope(
            observerLabel: "DM79po",
            observer: .init(latitude: 39.6, longitude: -104.7),
            entries: entries, now: now)
        XCTAssertEqual(scope.sites.map(\.id), ["W0ARP-10"])
    }

    func testDetailNamesTheSourceOfThePosition() {
        let entries = HeardStationMap.entries(
            stations: [station("KB5YZB-7", heard: 81, via: ["DRLNOD"])],
            directory: ["KB5YZB": record("KB5YZB")],
            gatewayGrids: [:])
        let detail = HeardStationMap.detail(
            for: entries[0], observer: .init(latitude: 39.6, longitude: -104.7), now: now)
        XCTAssertTrue(detail.contains("81 packets heard"), detail)
        XCTAssertTrue(detail.contains("DRLNOD"), detail)
        XCTAssertTrue(detail.contains("Position from HamDB"), detail)
    }

    // MARK: - Lookup candidates

    /// Only unplaced, plausible callsigns are worth a network round trip.
    func testLookupCandidatesSkipPlacedAndTacticalCallsigns() {
        let entries = HeardStationMap.entries(
            stations: [
                station("W0ARP-10"),      // placed by the gateway cache
                station("KB5YZB-7"),      // unplaced, real
                station("MAIL"),          // tactical alias
                station("KB5YZB-1"),      // same licensee as KB5YZB-7
            ],
            directory: [:],
            gatewayGrids: ["W0ARP-10": "DM79QL"])
        XCTAssertEqual(HeardStationMap.lookupCandidates(entries), ["KB5YZB"])
    }

    // MARK: - Clustering

    /// The bug this exists to prevent: every SSID of one licensee
    /// resolves through the same directory record, so four K0NTS
    /// stations landed on one point as four stacked markers — which
    /// reads as one marker and hides three stations.
    func testSameLicenceSSIDsCollapseToOneMarker() {
        let entries = HeardStationMap.entries(
            stations: [station("K0NTS-1"), station("K0NTS-7"),
                       station("K0NTS-10"), station("K0NTS-14")],
            directory: ["K0NTS": record("K0NTS", grid: "DM79gr")],
            gatewayGrids: [:])
        let clusters = HeardStationMap.clusters(entries)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].count, 4)
        XCTAssertEqual(HeardStationMap.clusterLabel(clusters[0]), "K0NTS ×4")
    }

    func testDistinctPositionsStayDistinct() {
        let entries = HeardStationMap.entries(
            stations: [station("W0ARP-10"), station("K0NTS-10")],
            directory: [:],
            gatewayGrids: ["W0ARP-10": "DM79QL", "K0NTS-10": "DM79GR"])
        XCTAssertEqual(HeardStationMap.clusters(entries).count, 2)
    }

    func testALoneStationKeepsItsOwnLabel() {
        let entries = HeardStationMap.entries(
            stations: [station("W0ARP-10")],
            directory: [:], gatewayGrids: ["W0ARP-10": "DM79QL"])
        XCTAssertEqual(
            HeardStationMap.clusterLabel(HeardStationMap.clusters(entries)[0]), "W0ARP-10")
    }

    /// Different licensees that happen to share a position are counted,
    /// not mislabelled as one of them.
    /// The busy station names the cluster, not whichever sorts first:
    /// W0ARP-10 at 2,657 packets shares DM79QL with N0HI-10 at one, and
    /// W0ARP-10 is what the operator is looking for.
    func testDifferentLicenseesAtOnePositionAreCounted() {
        let entries = HeardStationMap.entries(
            stations: [station("W0ARP-10", heard: 2657), station("N0HI-10", heard: 1)],
            directory: [:],
            gatewayGrids: ["W0ARP-10": "DM79QL", "N0HI-10": "DM79QL"])
        let clusters = HeardStationMap.clusters(entries)
        XCTAssertEqual(clusters.count, 1)
        // Names the first rather than hiding both behind a count —
        // "2 stations" reads as "my gateway is missing".
        XCTAssertEqual(HeardStationMap.clusterLabel(clusters[0]), "W0ARP-10 +1")
    }

    /// A stale SSID must not grey out a station heard a minute ago at
    /// the same site.
    func testClusterTakesTheLiveliestSignal() {
        let entries = HeardStationMap.entries(
            stations: [station("K0NTS-1", agoSeconds: 200_000),
                       station("K0NTS-7", agoSeconds: 60)],
            directory: ["K0NTS": record("K0NTS", grid: "DM79gr")],
            gatewayGrids: [:])
        let scope = HeardStationMap.scope(
            observerLabel: "DM79po",
            observer: .init(latitude: 39.6, longitude: -104.7),
            entries: entries, now: now)
        // By id, not by `first`. Sites sort by distance from the observer,
        // so which one leads depends on where the fan happens to put them —
        // nothing to do with what this test is about.
        let lively = scope.sites.first { $0.id == "K0NTS-7" }
        XCTAssertEqual(lively?.signal, .good)
        XCTAssertFalse(lively?.isStale ?? true)
    }

    // MARK: - The operator's own station

    /// A station hears its own transmissions come back digipeated, so
    /// without excluding it the operator appears twice — once as the
    /// centre marker and again as a heard station metres away.
    func testOwnCallsignIsExcluded() {
        let entries = HeardStationMap.entries(
            stations: [station("K0EPI-7"), station("W0ARP-10")],
            directory: [:], gatewayGrids: [:],
            excluding: "K0EPI-7")
        XCTAssertEqual(entries.map(\.callsign), ["W0ARP-10"])
    }

    /// Any SSID of the operator's own licence is still the operator.
    func testOwnCallsignExclusionIgnoresSSIDAndCase() {
        let entries = HeardStationMap.entries(
            stations: [station("k0epi-1"), station("K0EPI-7"), station("K0EPI")],
            directory: [:], gatewayGrids: [:],
            excluding: "K0EPI-7")
        XCTAssertTrue(entries.isEmpty)
    }

    /// With no callsign configured nothing is filtered — better to show
    /// a duplicate than to silently drop someone else's station.
    func testNoOwnCallsignFiltersNothing() {
        let entries = HeardStationMap.entries(
            stations: [station("K0EPI-7"), station("W0ARP-10")],
            directory: [:], gatewayGrids: [:], excluding: "")
        XCTAssertEqual(entries.count, 2)
    }

    // MARK: - Fanning

    /// Stations at one identical point cannot be separated by zooming,
    /// because they genuinely are at one point. Each gets its own
    /// position so each can be seen and picked.
    func testCoLocatedStationsGetDistinctPositions() {
        let entries = HeardStationMap.entries(
            stations: [station("K0NTS-1"), station("K0NTS-7"), station("K0NTS-10")],
            directory: ["K0NTS": record("K0NTS", latitude: 39.6, longitude: -105.3)],
            gatewayGrids: [:])
        let positions = HeardStationMap.fannedPositions(entries)
        XCTAssertEqual(positions.count, 3)
        let unique = Set(positions.values.map { "\($0.latitude),\($0.longitude)" })
        XCTAssertEqual(unique.count, 3, "every station needs its own point")
    }

    /// A lone station is never moved — its position is what it is.
    func testALoneStationIsNotOffset() throws {
        let entries = HeardStationMap.entries(
            stations: [station("W0ARP-10")],
            directory: ["W0ARP": record("W0ARP", latitude: 39.4918, longitude: -104.6398)],
            gatewayGrids: [:])
        let position = try XCTUnwrap(HeardStationMap.fannedPositions(entries)["W0ARP-10"])
        XCTAssertEqual(position.latitude, 39.4918, accuracy: 0.000001)
        XCTAssertEqual(position.longitude, -104.6398, accuracy: 0.000001)
    }

    /// The spread must stay inside what the position actually claims:
    /// tens of metres for an exact point, hundreds for a grid square.
    func testFanStaysWithinThePositionsOwnUncertainty() throws {
        let exact = HeardStationMap.entries(
            stations: [station("K0NTS-1"), station("K0NTS-7")],
            directory: ["K0NTS": record("K0NTS", latitude: 39.6, longitude: -105.3)],
            gatewayGrids: [:])
        let centre = GreatCircle.Point(latitude: 39.6, longitude: -105.3)
        for position in HeardStationMap.fannedPositions(exact).values {
            let metres = GreatCircle.kilometres(from: centre, to: position) * 1000
            XCTAssertLessThanOrEqual(metres, HeardStationMap.exactFanRadiusMetres + 1)
        }

        let gridded = HeardStationMap.entries(
            stations: [station("A-1"), station("A-2")],
            directory: [:],
            gatewayGrids: ["A-1": "DM79QL", "A-2": "DM79QL"])
        let gridCentre = try XCTUnwrap(Maidenhead.center(of: "DM79QL"))
        for position in HeardStationMap.fannedPositions(gridded).values {
            let metres = GreatCircle.kilometres(
                from: .init(gridCentre), to: position) * 1000
            XCTAssertLessThanOrEqual(metres, HeardStationMap.gridFanRadiusMetres + 1)
        }
    }

    /// The arrangement must not jitter between redraws.
    func testFanningIsDeterministic() {
        let stations = [station("K0NTS-7"), station("K0NTS-1"), station("K0NTS-10")]
        let directory = ["K0NTS": record("K0NTS", latitude: 39.6, longitude: -105.3)]
        let first = HeardStationMap.fannedPositions(
            HeardStationMap.entries(stations: stations, directory: directory, gatewayGrids: [:]))
        let second = HeardStationMap.fannedPositions(
            HeardStationMap.entries(stations: stations.reversed(),
                                    directory: directory, gatewayGrids: [:]))
        for (key, value) in first {
            XCTAssertEqual(second[key]?.latitude ?? 0, value.latitude, accuracy: 1e-9, key)
        }
    }

    /// One site per station, so the map count matches the list count.
    func testScopeHasOneSitePerStationNotPerPosition() {
        let entries = HeardStationMap.entries(
            stations: [station("K0NTS-1"), station("K0NTS-7"), station("W0ARP-10")],
            directory: ["K0NTS": record("K0NTS", latitude: 39.6, longitude: -105.3)],
            gatewayGrids: ["W0ARP-10": "DM79QL"])
        let scope = HeardStationMap.scope(
            observerLabel: "DM79po",
            observer: .init(latitude: 39.6, longitude: -104.7),
            entries: entries, now: now)
        XCTAssertEqual(Set(scope.sites.map(\.id)), ["K0NTS-1", "K0NTS-7", "W0ARP-10"])
    }

    /// A station sharing a point says so, rather than implying its
    /// marker is a precise fix.
    func testSharedPositionsAreDisclosed() {
        let entries = HeardStationMap.entries(
            stations: [station("K0NTS-1"), station("K0NTS-7")],
            directory: ["K0NTS": record("K0NTS", latitude: 39.6, longitude: -105.3)],
            gatewayGrids: [:])
        XCTAssertEqual(HeardStationMap.sharedPositionCounts(entries)["K0NTS-1"], 1)
        let scope = HeardStationMap.scope(
            observerLabel: "DM79po",
            observer: .init(latitude: 39.6, longitude: -104.7),
            entries: entries, now: now)
        XCTAssertTrue(
            scope.sites.first?.detail.contains("Shares an exact position") == true,
            scope.sites.first?.detail ?? "")
    }

    // MARK: - What a position is *of*

    /// Precision is not accuracy. A licence address is exact but
    /// describes the licensee; an RMS grid describes the gateway. The
    /// exact value is a refinement only when the two agree.
    func testExactPositionIsUsedWhenItAgreesWithTheRegisteredGrid() throws {
        // W0ARP's licence address really does fall inside DM79QL.
        let entries = HeardStationMap.entries(
            stations: [station("W0ARP-10")],
            directory: ["W0ARP": record("W0ARP", grid: "DM79ql",
                                        latitude: 39.4918279, longitude: -104.6398437)],
            gatewayGrids: ["W0ARP-10": "DM79QL"])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.confidence, .exact)
        XCTAssertEqual(entry.position?.latitude ?? 0, 39.4918279, accuracy: 0.000001)
    }

    /// When they disagree the two sources are describing different
    /// places. The one about the right entity wins, and the conflict is
    /// reported rather than silently resolved.
    func testDisagreementFallsBackToTheRegisteredGridAndSaysSo() throws {
        let entries = HeardStationMap.entries(
            stations: [station("W0ARP-10")],
            directory: ["W0ARP": record("W0ARP", grid: "DM79ql",
                                        latitude: 51.5074, longitude: -0.1278)],
            gatewayGrids: ["W0ARP-10": "DM79QL"])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.confidence, .gridSquare)
        XCTAssertTrue(entry.positionSource?.contains("disagrees") == true,
                      entry.positionSource ?? "")
    }

    func testGridContainmentIsTheAgreementTest() {
        XCTAssertTrue(HeardStationMap.gridContains(
            "DM79QL", .init(latitude: 39.4918279, longitude: -104.6398437)))
        XCTAssertFalse(HeardStationMap.gridContains(
            "DM79QL", .init(latitude: 51.5074, longitude: -0.1278)))
    }

    // MARK: - The directory layer

    /// The whole directory on the map — but only what can be placed with
    /// what is already cached. No entry may trigger a lookup: a harvested
    /// directory runs to hundreds of names, and bulk-fetching them is the
    /// runaway the terrain downloader once had.
    func testDirectoryLayerShowsOnlyThePlaceable() {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "DRLNOD", callsign: "KE0NCQ", service: "N"), at: now)
        aliases.record(.init(alias: "SOLBPQ", callsign: "N0HI-7", service: "N"), at: now)

        let entries = HeardStationMap.directoryNodeEntries(
            aliases: aliases,
            alreadyShown: [],
            directory: ["KE0NCQ": record("KE0NCQ", latitude: 39.65, longitude: -104.98)],
            announcedGrids: [:],
            stations: [])
        XCTAssertEqual(entries.map(\.callsign), ["DRLNOD"],
                       "N0HI has never been looked up — SOLBPQ stays off the layer")
        XCTAssertTrue(entries.allSatisfy(\.isPlaced))
    }

    /// A name already on the map belongs to the layer that knows more
    /// about it; the operator's own callsign is the centre marker.
    func testDirectoryLayerYieldsToExistingMarkersAndSelf() {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "DRLNOD", callsign: "KE0NCQ", service: "N"), at: now)
        aliases.record(.init(alias: "EPINOD", callsign: "K0EPI-7", service: "N"), at: now)
        let directory = [
            "KE0NCQ": record("KE0NCQ", latitude: 39.65, longitude: -104.98),
            "K0EPI": record("K0EPI", latitude: 39.0, longitude: -105.0)
        ]

        XCTAssertTrue(HeardStationMap.directoryNodeEntries(
            aliases: aliases, alreadyShown: ["DRLNOD"], directory: directory,
            announcedGrids: [:], stations: [], excluding: "K0EPI-7").isEmpty)
    }

    /// YZBBPQ beside the heard KB5YZB-7 read as two stations (field
    /// capture 2026-08-29 04:55) — an alias whose callsign is already on
    /// the map is the same box wearing another hat.
    func testDirectoryLayerSkipsAliasesOfStationsAlreadyShown() {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "YZBBPQ", callsign: "KB5YZB-7", service: "N"), at: now)
        XCTAssertTrue(HeardStationMap.directoryNodeEntries(
            aliases: aliases,
            alreadyShown: [],
            shownCallsigns: ["KB5YZB-7"],
            directory: ["KB5YZB": record("KB5YZB", latitude: 39.6, longitude: -104.8)],
            announcedGrids: [:],
            stations: []).isEmpty)
    }

    /// When a heard station absorbs its box's aliases, the fold must not
    /// be silent: the heard marker carries the node names, and the
    /// Find Positions budget skips bases that could never draw.
    func testFoldedNodeIdentitiesAreNamedAndNotLookedUp() {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "ZIABBS", callsign: "K0ZIA-1", service: "N"), at: now)
        aliases.record(.init(alias: "ZIACHT", callsign: "K0ZIA-7", service: "N"), at: now)
        aliases.record(.init(alias: "INRMS", callsign: "W9OTR", service: "N"), at: now)

        let badges = HeardStationMap.nodeAliasesByHeardBase(
            aliases: aliases, heardCalls: ["K0ZIA-14"])
        XCTAssertEqual(badges, ["K0ZIA": ["ZIABBS", "ZIACHT"]])

        let candidates = HeardStationMap.directoryLookupCandidates(
            aliases: aliases, cachedCallsigns: [], heardBases: ["K0ZIA"])
        XCTAssertEqual(candidates, ["W9OTR"],
                       "the press's budget goes to claims that can actually draw")
    }

    /// ZIABBS resolves to K0ZIA-1 while the heard station is K0ZIA-14 —
    /// sibling SSIDs of one box (field capture 2026-08-29 05:24). A heard
    /// station under *any* SSID of a base owns that box's marker.
    func testDirectoryLayerSkipsSiblingSSIDsOfHeardStations() {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "ZIABBS", callsign: "K0ZIA-1", service: "N"), at: now)
        XCTAssertTrue(HeardStationMap.directoryNodeEntries(
            aliases: aliases,
            alreadyShown: [],
            shownCallsigns: ["K0ZIA-14"],
            directory: ["K0ZIA": record("K0ZIA", latitude: 38.9, longitude: -104.7)],
            announcedGrids: [:],
            stations: []).isEmpty)
    }

    /// The ZI* family: four aliases resolving to four SSIDs of K0ZIA —
    /// one box whose services live on different SSIDs, which drew four
    /// diamonds at one address (field capture 2026-08-29 05:16). Grouped
    /// by *base* callsign: one diamond.
    func testDirectoryLayerCollapsesSSIDsOfOneBase() throws {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "ZIARMS", callsign: "K0ZIA-10", service: "N"), at: now)
        aliases.record(.init(alias: "ZIABBS", callsign: "K0ZIA-1", service: "N"), at: now)
        aliases.record(.init(alias: "ZIACHT", callsign: "K0ZIA-7", service: "N"), at: now)
        let entries = HeardStationMap.directoryNodeEntries(
            aliases: aliases,
            alreadyShown: [],
            directory: ["K0ZIA": record("K0ZIA", latitude: 38.9, longitude: -104.7)],
            announcedGrids: [:],
            stations: [])
        XCTAssertEqual(entries.count, 1)
        let name = try XCTUnwrap(entries.first?.name)
        XCTAssertTrue(name.contains("ZIACHT") && name.contains("ZIARMS"), name)
    }

    /// DRL, DRLBBS and DRLNOD are one box offering three services — one
    /// diamond, with the other names riding along in its detail.
    func testDirectoryLayerDrawsOneMarkerPerBox() throws {
        var aliases = NodeAliasDirectory()
        for name in ["DRLNOD", "DRLBBS", "DRL"] {
            aliases.record(.init(alias: name, callsign: "KE0NCQ", service: "N"), at: now)
        }
        let entries = HeardStationMap.directoryNodeEntries(
            aliases: aliases,
            alreadyShown: [],
            directory: ["KE0NCQ": record("KE0NCQ", latitude: 39.65, longitude: -104.98)],
            announcedGrids: [:],
            stations: [])
        XCTAssertEqual(entries.map(\.callsign), ["DRL"],
                       "alphabetically first alias stands for the box")
        let name = try XCTUnwrap(entries.first?.name)
        XCTAssertTrue(name.contains("DRLBBS") && name.contains("DRLNOD"), name)
    }

    /// Lookups for the directory layer are bounded and ordered by how
    /// many nodes vouch for each station — never "look up everything".
    func testDirectoryLookupCandidatesAreBoundedAndRanked() {
        var aliases = NodeAliasDirectory()
        for index in 0..<60 {
            aliases.record(.init(alias: "N\(index)X", callsign: "N\(index)XA", service: "N"),
                           at: now, from: "COSCO")
        }
        aliases.record(.init(alias: "POPULAR", callsign: "W0POP-1", service: "N"),
                       at: now, from: "COSCO")
        aliases.record(.init(alias: "POPULAR", callsign: "W0POP-1", service: "N"),
                       at: now.addingTimeInterval(1), from: "SOLBPQ")

        let candidates = HeardStationMap.directoryLookupCandidates(
            aliases: aliases, cachedCallsigns: [], limit: 40)
        XCTAssertEqual(candidates.count, 40, "hard cap per press")
        XCTAssertEqual(candidates.first, "W0POP",
                       "two nodes vouch for it; everything else has one")
        XCTAssertTrue(HeardStationMap.directoryLookupCandidates(
            aliases: aliases, cachedCallsigns: ["W0POP"], limit: 40)
            .allSatisfy { $0 != "W0POP" }, "already-cached callsigns are not re-fetched")
    }

    /// Filling the layer from this app's own cache is a different question
    /// from asking hamdb.org, and must not inherit the rationing that only
    /// the second one needs: a position already on disk is a marker the map
    /// would otherwise fail to draw for no reason (field ask 2026-09-03).
    func testTheCacheReadCoversTheWholeDirectoryUnlikeTheRemoteAsk() {
        var aliases = NodeAliasDirectory()
        for index in 0..<60 {
            aliases.record(.init(alias: "N\(index)X", callsign: "N\(index)XA", service: "N"),
                           at: now, from: "COSCO")
        }

        let all = HeardStationMap.directoryOperatorCallsigns(aliases: aliases)
        XCTAssertEqual(all.count, 60, "no cap on reading our own cache")

        XCTAssertEqual(
            HeardStationMap.directoryLookupCandidates(
                aliases: aliases, cachedCallsigns: [], limit: 40).count,
            40,
            "the remote ask stays rationed")
    }

    /// The cache read wants the box whose position is already known, even
    /// when it is heard and even when it is cached — the exclusions exist
    /// to spend a network budget, and there is no budget here.
    func testTheCacheReadKeepsHeardAndCachedOperators() {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "ZIABBS", callsign: "K0ZIA-1", service: "N"), at: now)
        aliases.record(.init(alias: "INRMS", callsign: "W9OTR", service: "N"), at: now)

        XCTAssertEqual(
            Set(HeardStationMap.directoryOperatorCallsigns(aliases: aliases)),
            ["K0ZIA", "W9OTR"])
        XCTAssertEqual(
            HeardStationMap.directoryLookupCandidates(
                aliases: aliases, cachedCallsigns: ["W9OTR"], heardBases: ["K0ZIA"]),
            [],
            "nothing left worth a round trip")
    }

    /// A station that beaconed its own locator is placed by it — the
    /// station's own claim about itself, better than nothing cached.
    func testDirectoryLayerFallsBackToTheStationsOwnBeacon() throws {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "SOLBPQ", callsign: "N0HI-7", service: "N"), at: now)
        let entry = try XCTUnwrap(HeardStationMap.directoryNodeEntries(
            aliases: aliases, alreadyShown: [], directory: [:],
            announcedGrids: ["N0HI-7": "DM79LQ"], stations: []).first)
        XCTAssertEqual(entry.callsign, "SOLBPQ")
        XCTAssertTrue(entry.isPlaced)
        XCTAssertEqual(entry.gridSquare, "DM79LQ")
        XCTAssertTrue(entry.positionSource?.contains("beacon") == true)
    }

    // MARK: - Node aliases

    /// The whole point: DRLNOD is not a licence, so no directory has it,
    /// but its operator announces it and the operator can be placed.
    func testAliasIsPlacedViaItsOperator() throws {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "DRLNOD", callsign: "KE0NCQ", service: "N"), at: now)

        let entries = HeardStationMap.aliasEntries(
            aliases: aliases,
            usedAliases: ["DRLNOD"],
            directory: ["KE0NCQ": record("KE0NCQ", latitude: 39.65, longitude: -104.98)],
            stations: [])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.callsign, "DRLNOD")
        XCTAssertTrue(entry.isNodeAlias)
        XCTAssertNotNil(entry.position)
    }

    /// A node is not co-located with its operator's mailing address —
    /// it usually sits on a hilltop. The position is a lead, and must be
    /// marked as one rather than drawn like a fix.
    func testAliasPositionIsMarkedAsInferredNotExact() throws {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "DRLNOD", callsign: "KE0NCQ", service: "N"), at: now)
        let entry = try XCTUnwrap(HeardStationMap.aliasEntries(
            aliases: aliases, usedAliases: ["DRLNOD"],
            directory: ["KE0NCQ": record("KE0NCQ", latitude: 39.65, longitude: -104.98)],
            stations: []).first)

        XCTAssertEqual(entry.confidence, .inferredFromOperator)
        XCTAssertFalse(entry.isExactPosition)
        XCTAssertTrue(entry.positionSource?.contains("operator") == true,
                      entry.positionSource ?? "")

        // And it reaches the map flagged so the renderer can draw it hollow.
        let scope = HeardStationMap.scope(
            observerLabel: "DM79po",
            observer: .init(latitude: 39.6, longitude: -104.7),
            entries: [entry], now: now)
        XCTAssertTrue(scope.sites.first?.isApproximate == true)
    }

    /// An alias nobody has announced stays unplaced rather than guessed.
    func testUnknownAliasIsNotPlaced() {
        XCTAssertTrue(HeardStationMap.aliasEntries(
            aliases: NodeAliasDirectory(), usedAliases: ["MYSTERY"],
            directory: [:], stations: []).isEmpty)
    }

    /// Only aliases actually used in a path are worth showing — the
    /// point is explaining this station's hops, not listing every node.
    func testAliasesInUseComeFromViaPaths() {
        let found = HeardStationMap.aliasesInUse([
            station("KB5YZB-1", via: ["DRLNOD"]),
            station("N0BN", via: ["AB0VZ-7"]),
            station("KN6VV-1", via: ["HORSE"]),
        ])
        // AB0VZ-7 is a digipeating station, not a tactical alias.
        XCTAssertEqual(found, ["DRLNOD", "HORSE"])
    }

    /// An alias whose operator has not been located yet is listed
    /// unplaced rather than dropped — a via-path hop that cannot be
    /// located is a fact worth showing, and it is what a lookup fixes.
    func testKnownAliasWithUnplacedOperatorIsListedNotDropped() throws {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "DRLNOD", callsign: "KE0NCQ", service: "N"), at: now)
        let entries = HeardStationMap.aliasEntries(
            aliases: aliases, usedAliases: ["DRLNOD"],
            directory: [:], stations: [])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.callsign, "DRLNOD")
        XCTAssertFalse(entry.isPlaced)
        XCTAssertTrue(entry.isNodeAlias)
    }

    /// Looking up "DRLNOD" would fail — it is not a licence. The
    /// operator that announced it is what the directory can answer.
    func testLookupCandidatesUseTheOperatorNotTheAlias() {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "DRLNOD", callsign: "KE0NCQ", service: "N"), at: now)
        let entries = HeardStationMap.aliasEntries(
            aliases: aliases, usedAliases: ["DRLNOD"],
            directory: [:], stations: [])
        XCTAssertEqual(
            HeardStationMap.lookupCandidates(entries, aliases: aliases), ["KE0NCQ"])
    }
}
