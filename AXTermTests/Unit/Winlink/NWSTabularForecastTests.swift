import XCTest
@testable import AXTerm

/// The fixture is a verbatim SFTCO product received 2026-08-24, Winlink
/// footer and all — including the two quirks that matter: the legend
/// block above the table, and the `$$` terminator with non-forecast text
/// after it.
final class NWSTabularForecastTests: XCTestCase {

    private let sftco = """
    FPUS65 KBOU 240648
    SFTCO\u{20}
    COZ001>014-017>023-030>051-058>099-251100-

    Tabular State Forecast for Colorado
    National Weather Service Denver/Boulder CO
    1247 AM MDT Mon Aug 24 2026

    ROWS INCLUDE...
       Daily predominant daytime weather 6AM-6PM
       Forecast temperatures...early morning low/daytime high
             Probability of precipitation nighttime 6PM-6AM/daytime 6AM-6PM
              - indicates temperatures below zero
             MM indicates missing data


       FCST     FCST     FCST     FCST     FCST     FCST     FCST\u{20}
       Tue      Wed      Thu      Fri      Sat      Sun      Mon\u{20}
       Aug 25   Aug 26   Aug 27   Aug 28   Aug 29   Aug 30   Aug 31\u{20}


    ...NORTHEAST COLORADO...
       DENVER
       Ptcldy   Tstrms   Ptcldy   Sunny    Ptcldy   Ptcldy   Ptcldy\u{20}
       62/88    60/87    60/90    61/94    62/94    63/92    62/91\u{20}
        30/30    40/50    40/30    30/10    20/20    20/30    30/30\u{20}

       BURLINGTON
       Ptcldy   Ptcldy   Sunny    Sunny    Vryhot   Sunny    Sunny\u{20}
       63/89    59/86    59/87    61/94    62/96    62/94    61/91\u{20}
        30/40    50/20    60/10    30/00    10/00    20/00    30/10\u{20}


    ...SOUTHEAST COLORADO...
       COLORADO SPRINGS
       Ptcldy   Ptcldy   Ptcldy   Sunny    Sunny    Ptcldy   Ptcldy\u{20}
       58/86    56/83    55/85    56/89    58/91    59/89    58/87\u{20}
        30/60    60/80    40/50    40/30    10/20    20/30    30/30\u{20}

       PUEBLO
       Sunny    Ptcldy   Sunny    Sunny    Vryhot   Vryhot   Sunny\u{20}
       62/92    60/87    59/90    60/95    62/97    63/96    62/94\u{20}
        40/60    70/50    50/20    40/00    20/10    20/10    20/10\u{20}

    $$

    =====
    Thanks for using Winlink, an Amateur Radio Safety Foundation
    sponsored project. For information about Winlink or to manage
    your Winlink account please visit:
    https://www.winlink.org
    """

    // MARK: - Shape

    func testParsesHeaderMetadata() throws {
        let forecast = try XCTUnwrap(NWSTabularForecast.parse(sftco))
        XCTAssertEqual(forecast.productId, "SFTCO")
        XCTAssertEqual(forecast.title, "Tabular State Forecast for Colorado")
        XCTAssertEqual(forecast.office, "National Weather Service Denver/Boulder CO")
        XCTAssertEqual(forecast.issued, "1247 AM MDT Mon Aug 24 2026")
    }

    /// The day count comes from the product's own `FCST` row, and the
    /// dates keep their internal space — a naive whitespace split would
    /// turn "Aug 25" into two columns and double the count.
    func testDayColumnsSurviveTheirInternalSpace() throws {
        let forecast = try XCTUnwrap(NWSTabularForecast.parse(sftco))
        XCTAssertEqual(forecast.days.count, 7)
        XCTAssertEqual(forecast.days.first?.weekday, "Tue")
        XCTAssertEqual(forecast.days.first?.date, "Aug 25")
        XCTAssertEqual(forecast.days.last?.date, "Aug 31")
    }

    func testSectionsAndPlaces() throws {
        let forecast = try XCTUnwrap(NWSTabularForecast.parse(sftco))
        XCTAssertEqual(forecast.sections.map(\.title),
                       ["Northeast Colorado", "Southeast Colorado"])
        XCTAssertEqual(forecast.sections[0].places.map(\.name), ["DENVER", "BURLINGTON"])
        // A two-word city name must not be mistaken for a data row.
        XCTAssertEqual(forecast.sections[1].places.map(\.name), ["COLORADO SPRINGS", "PUEBLO"])
        XCTAssertEqual(forecast.placeCount, 4)
    }

    // MARK: - Values

    func testCellValuesMatchTheProduct() throws {
        let forecast = try XCTUnwrap(NWSTabularForecast.parse(sftco))
        let denver = try XCTUnwrap(forecast.sections.first?.places.first)
        XCTAssertEqual(denver.cells.count, 7)

        // Tuesday: Ptcldy, 62/88, PoP 30/30.
        XCTAssertEqual(denver.cells[0].weatherCode, "Ptcldy")
        XCTAssertEqual(denver.cells[0].low, 62)
        XCTAssertEqual(denver.cells[0].high, 88)
        XCTAssertEqual(denver.cells[0].popNight, 30)
        XCTAssertEqual(denver.cells[0].popDay, 30)

        // Wednesday is the storm day — 40 night / 50 day.
        XCTAssertEqual(denver.cells[1].weatherCode, "Tstrms")
        XCTAssertEqual(denver.cells[1].peakPop, 50)
    }

    /// `00` is a real forecast value, not a missing one.
    func testZeroProbabilityIsAValueNotAGap() throws {
        let forecast = try XCTUnwrap(NWSTabularForecast.parse(sftco))
        let pueblo = try XCTUnwrap(forecast.sections.last?.places.last)
        XCTAssertEqual(pueblo.cells[3].popDay, 0)
    }

    // MARK: - Naming

    func testKnownAbbreviationsExpandAndUnknownOnesAreKept() {
        let known = NWSTabularForecast.Cell(
            weatherCode: "Ptcldy", low: 1, high: 2, popNight: 0, popDay: 0)
        XCTAssertEqual(known.weatherName, "Partly Cloudy")
        XCTAssertEqual(known.symbolName, "cloud.sun")

        // Never guessed at: an unrecognised code is shown as written.
        let unknown = NWSTabularForecast.Cell(
            weatherCode: "Zzzzzz", low: 1, high: 2, popNight: 0, popDay: 0)
        XCTAssertEqual(unknown.weatherName, "Zzzzzz")
        XCTAssertEqual(unknown.symbolName, "questionmark.circle")
    }

    // MARK: - Rejection

    /// Anything that is not an SFT product must fall through to the raw
    /// body rather than be half-rendered.
    func testNonForecastBodiesAreRejected() {
        XCTAssertNil(NWSTabularForecast.parse("Just an ordinary radiogram.\r\nNothing tabular here."))
        XCTAssertNil(NWSTabularForecast.parse(""))
    }

    /// Right product family, but the table never arrived — a truncated
    /// transfer must not produce a confident empty forecast.
    func testProductWithoutADayHeaderIsRejected() {
        let truncated = """
        FPUS65 KBOU 240648
        SFTCO
        Tabular State Forecast for Colorado
        National Weather Service Denver/Boulder CO
        """
        XCTAssertNil(NWSTabularForecast.parse(truncated))
    }

    /// A place whose three-row cadence is cut short is dropped, not
    /// padded with invented cells.
    func testPlaceWithIncompleteRowsIsDropped() throws {
        let clipped = """
        FPUS65 KBOU 240648
        SFTCO

           FCST     FCST\u{20}
           Tue      Wed\u{20}
           Aug 25   Aug 26\u{20}

        ...NORTHEAST COLORADO...
           DENVER
           Ptcldy   Tstrms\u{20}
           62/88    60/87\u{20}
            30/30    40/50\u{20}

           BOULDER
           Sunny    Sunny\u{20}
        $$
        """
        let forecast = try XCTUnwrap(NWSTabularForecast.parse(clipped))
        XCTAssertEqual(forecast.sections.flatMap(\.places).map(\.name), ["DENVER"])
    }

    /// Text after `$$` is the Winlink footer, not forecast data.
    func testFooterAfterTerminatorIsIgnored() throws {
        let forecast = try XCTUnwrap(NWSTabularForecast.parse(sftco))
        let names = forecast.sections.flatMap(\.places).map(\.name)
        XCTAssertFalse(names.contains { $0.contains("Winlink") || $0.contains("=====") })
    }
}
