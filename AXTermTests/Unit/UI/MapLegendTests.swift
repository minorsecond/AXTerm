import SwiftUI
import XCTest
@testable import AXTerm

/// The key beside a station map.
final class MapLegendTests: XCTestCase {

    /// `ForEach` identifies the rows by label. Two entries sharing one would
    /// silently drop a colour from the key — the swatch would vanish and the
    /// map would keep drawing it.
    func testEntryLabelsAreUniqueWithinAKind() {
        for kind in [MapLegend.Kind.recency, .linkQuality] {
            let labels = kind.entries.map(\.label)
            XCTAssertEqual(Set(labels).count, labels.count, "\(kind.title) has a duplicate label")
        }
    }

    /// Every swatch is explained on hover. A colour with no detail is the
    /// decoration this legend exists to avoid.
    func testEveryEntryCarriesADetail() {
        for kind in [MapLegend.Kind.recency, .linkQuality] {
            for entry in kind.entries {
                XCTAssertFalse(entry.label.isEmpty, "\(kind.title)")
                XCTAssertFalse(entry.detail.isEmpty, "\(kind.title): \(entry.label)")
            }
        }
    }

    /// The two kinds measure different things and must not describe
    /// themselves the same way — recency is when we last heard a station,
    /// link quality is how often a gateway answered us.
    func testTheTwoKindsAreDistinguishable() {
        XCTAssertNotEqual(MapLegend.Kind.recency.title, MapLegend.Kind.linkQuality.title)
        XCTAssertNotEqual(MapLegend.Kind.recency.footnote, MapLegend.Kind.linkQuality.footnote)
    }

    /// The footnote is the caveat that makes the colours honest, so it is
    /// part of the key rather than an optional extra. It used to be the only
    /// thing the disclosure hid, which is why that control read as broken.
    func testEveryKindStatesWhatTheColourIsMeasuredFrom() {
        for kind in [MapLegend.Kind.recency, .linkQuality] {
            XCTAssertFalse(kind.footnote.isEmpty, "\(kind.title)")
        }
    }
}
