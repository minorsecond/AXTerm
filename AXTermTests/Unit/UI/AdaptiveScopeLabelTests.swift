import XCTest
@testable import AXTerm

/// What the adaptive chip says it is describing.
///
/// Once the tuner keeps a figure per channel, a bare "K1 P64" is ambiguous in
/// a way it never was before: the operator has to be able to tell which radio
/// it is about, or a per-radio number is worse than the global one it replaced.
final class AdaptiveScopeLabelTests: XCTestCase {

    private func params(destination: String?, path: String?, radio: RadioID?) -> AdaptiveParams {
        AdaptiveParams(settings: TxAdaptiveSettings(), lossRate: nil, etx: nil, srtt: nil,
                       updatedAt: Date(), destination: destination, pathSignature: path, radio: radio)
    }

    /// With one radio there is nothing to disambiguate, and naming it would be
    /// noise on every row.
    func testOneRadioIsNotNamed() {
        let p = params(destination: "W0ARP-10", path: "", radio: RadioID(rawValue: "a"))
        XCTAssertEqual(AdaptiveScopeLabel.text(for: p, radioName: { _ in "Direwolf" },
                                               hasMultipleRadios: false),
                       "W0ARP-10")
    }

    /// With several, every figure says which channel it came from.
    func testSeveralRadiosAreAlwaysNamed() {
        let p = params(destination: "W0ARP-10", path: "DRLNOD", radio: RadioID(rawValue: "b"))
        XCTAssertEqual(AdaptiveScopeLabel.text(for: p, radioName: { _ in "IC-705" },
                                               hasMultipleRadios: true),
                       "W0ARP-10 via DRLNOD · IC-705")
    }

    /// A channel-wide figure names the channel rather than a destination.
    func testAChannelFigureNamesTheChannel() {
        let p = params(destination: nil, path: nil, radio: RadioID(rawValue: "b"))
        XCTAssertEqual(AdaptiveScopeLabel.text(for: p, radioName: { _ in "IC-705" },
                                               hasMultipleRadios: true),
                       "IC-705 channel")
    }

    /// The operator's configured baseline belongs to no radio and must not
    /// pretend otherwise.
    func testTheBaselineIsNotAttributedToARadio() {
        let p = params(destination: nil, path: nil, radio: nil)
        XCTAssertEqual(AdaptiveScopeLabel.text(for: p, radioName: { _ in "IC-705" },
                                               hasMultipleRadios: true),
                       "All channels")
    }

    /// A radio whose name we cannot resolve still gets said, rather than the
    /// row silently losing its attribution.
    func testAnUnnamedRadioStillGetsAttributed() {
        let p = params(destination: nil, path: nil, radio: RadioID(rawValue: "vhf"))
        XCTAssertEqual(AdaptiveScopeLabel.text(for: p, radioName: { _ in nil },
                                               hasMultipleRadios: true),
                       "vhf channel")
    }
}
