import Foundation

/// The coverage evidence the map draws rings from, already narrowed to the
/// radios that carry each family.
///
/// The view is handed the answer rather than the whole picture plus the rules
/// for narrowing it: which radios carry APRS is the sidebar's business, and a
/// map that worked it out again would be a second place for the two to
/// disagree.
nonisolated struct MapCoverageEvidence: Equatable, Sendable {
    /// Digipeaters that put one of our own frames back on the air, heard on a
    /// radio carrying APRS.
    var repeatedUsAPRS: [String: Date] = [:]
    /// Stations decoded with nothing in between, on a radio carrying APRS.
    var heardDirectAPRS: [String: Date] = [:]
    /// The same, on a radio carrying AX.25.
    var heardDirectAX25: [String: Date] = [:]

    init() {}

    init(_ evidence: CoverageEvidence, families: [RadioID: Set<RadioTrafficFamily>]) {
        func radios(carrying family: RadioTrafficFamily) -> Set<RadioID> {
            Set(families.filter { $0.value.contains(family) }.keys)
        }
        let aprs = radios(carrying: .aprs)
        let ax25 = radios(carrying: .ax25)
        repeatedUsAPRS = evidence.repeatedUs(on: aprs)
        heardDirectAPRS = evidence.heardDirect(on: aprs)
        heardDirectAX25 = evidence.heardDirect(on: ax25)
    }
}
