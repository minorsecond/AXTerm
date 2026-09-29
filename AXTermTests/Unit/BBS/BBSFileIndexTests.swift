import XCTest
@testable import AXTerm

/// The catalogue, and the one property that has to hold: a caller cannot name
/// a file that was not scanned.
final class BBSFileIndexTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func file(_ name: String, area: String = "OPS", bytes: Int = 1_024)
        -> BBSSharedFile {
        BBSSharedFile(area: area, name: name, byteCount: bytes,
                      modifiedAt: t0, about: "")
    }

    private func index(_ files: [BBSSharedFile]) -> BBSFileIndex {
        let areas = Set(files.map(\.area)).map { BBSFileArea(name: $0) }
        return BBSFileIndex(areas: areas, files: files)
    }

    // MARK: - Resolution

    func testResolvesAPlainName() {
        let sut = index([file("netscript.txt")])
        XCTAssertEqual(sut.resolve("netscript.txt"), .found(file("netscript.txt")))
    }

    /// Callers type blind on a radio link.
    func testResolutionIgnoresCase() {
        let sut = index([file("NetScript.TXT")])
        guard case .found(let match) = sut.resolve("netscript.txt") else {
            return XCTFail("case should not matter")
        }
        XCTAssertEqual(match.name, "NetScript.TXT")
    }

    func testUnknownNameIsNotFound() {
        XCTAssertEqual(index([file("a.txt")]).resolve("b.txt"), .notFound)
    }

    /// **The safety property.** The index holds basenames and resolution is a
    /// lookup, never a path join, so an escape attempt simply matches nothing.
    func testTraversalAttemptsMatchNothing() {
        let sut = index([file("netscript.txt")])
        for attempt in ["../../etc/passwd", "/etc/passwd", "..", "OPS/../../../etc/passwd",
                        "./netscript.txt", "~/.ssh/id_rsa"] {
            XCTAssertEqual(sut.resolve(attempt), .notFound, "\(attempt) resolved to something")
        }
    }

    func testAreaQualifierNarrowsToOneArea() {
        let sut = index([file("readme.txt", area: "OPS"),
                         file("readme.txt", area: "FORMS")])
        guard case .found(let match) = sut.resolve("FORMS/readme.txt") else {
            return XCTFail("qualified name should resolve")
        }
        XCTAssertEqual(match.area, "FORMS")
    }

    /// Two areas, one name: say which rather than guessing, and name them so
    /// the caller can answer without another listing.
    func testDuplicateNamesAreAmbiguous() {
        let sut = index([file("readme.txt", area: "OPS"),
                         file("readme.txt", area: "FORMS")])
        XCTAssertEqual(sut.resolve("readme.txt"), .ambiguous(areas: ["FORMS", "OPS"]))
    }

    func testEmptyRequestIsNotFound() {
        XCTAssertEqual(index([file("a.txt")]).resolve("   "), .notFound)
    }

    func testFilesInAreaAreSortedAndFiltered() {
        let sut = index([file("z.txt", area: "OPS"), file("a.txt", area: "OPS"),
                         file("m.txt", area: "FORMS")])
        XCTAssertEqual(sut.files(in: "ops").map(\.name), ["a.txt", "z.txt"])
    }

    // MARK: - Area names

    func testAreaNamesAreNormalised() {
        XCTAssertEqual(BBSFileArea.normalize(" net scripts "), "NETSCRIPTS")
        XCTAssertEqual(BBSFileArea.normalize("ICS-213"), "ICS213")
    }

    // MARK: - Rendering

    func testSizesAreCompact() {
        XCTAssertEqual(BBSFileIndex.size(512), "512B")
        XCTAssertEqual(BBSFileIndex.size(4_096), "4K")
        XCTAssertEqual(BBSFileIndex.size(146_432), "143K")
        XCTAssertEqual(BBSFileIndex.size(1_572_864), "1.5M")
        XCTAssertEqual(BBSFileIndex.size(52_428_800), "50M")
    }

    /// The number that decides whether a caller wants the file at all.
    func testDurationsReadInMinutesAndHours() {
        XCTAssertEqual(BBSFileIndex.duration(bytes: 1_000, bytesPerSecond: 90), "<1m")
        XCTAssertEqual(BBSFileIndex.duration(bytes: 10_000, bytesPerSecond: 90), "2m")
        XCTAssertEqual(BBSFileIndex.duration(bytes: 146_432, bytesPerSecond: 90), "28m")
        XCTAssertEqual(BBSFileIndex.duration(bytes: 1_048_576, bytesPerSecond: 90), "3h14m")
        XCTAssertEqual(BBSFileIndex.duration(bytes: 100_000_000, bytesPerSecond: 90), ">1d")
    }

    func testDurationWithNoMeasurementSaysSo() {
        XCTAssertEqual(BBSFileIndex.duration(bytes: 1_000, bytesPerSecond: 0), "?")
    }

    // MARK: - Text detection

    func testTextFilesAreRecognisedByExtension() {
        XCTAssertTrue(file("net.txt").isText)
        XCTAssertTrue(file("roster.CSV").isText)
        XCTAssertFalse(file("map.png").isText)
        XCTAssertFalse(file("archive.zip").isText)
        XCTAssertFalse(file("README").isText)
    }
}
