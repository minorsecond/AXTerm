import Foundation

/// Whether an AX.25 destination field is an address at all.
///
/// APRS puts data where AX.25 puts a callsign. Two kinds, both of which were
/// being drawn as stations on the analytics graph until 2026-09-17:
///
/// - A **Mic-E** frame encodes the sender's latitude in the destination. It is
///   a coordinate, so a moving station mints a fresh one on every beacon. A
///   single afternoon of local traffic produced a hundred phantom nodes, every
///   one of them isolated, strung out in a line because they sort almost in
///   geographic order.
/// - An **APRS tocall** (`APxxxx`) names the software that sent the frame, not
///   a station. APDW17 is Direwolf, APZAXT is this app.
///
/// Both belong to the frame, not to the network, and neither is somewhere a
/// packet can be sent.
nonisolated enum APRSDestinationAddress {

    /// Mic-E data type identifiers. The current ones are `'` and `` ` ``; the
    /// two control codes are the original Mic-E and Mic-E "old" forms, still
    /// heard from older trackers.
    private static let micEDataTypes: Set<UInt8> = [0x1C, 0x1D, 0x27, 0x60]

    /// `AP` followed by four more characters, which is the whole APRS tocall
    /// space. Deliberately anchored to six characters: `AP2ABC` is a real
    /// Pakistani callsign of the same shape, so this is only ever applied to
    /// the destination field of a UI frame, where a worked station does not
    /// appear.
    private static let tocallPattern = #"^AP[A-Z0-9]{4}$"#

    /// True when the destination carries APRS data rather than naming a station.
    ///
    /// Restricted to UI frames. A connected-mode frame's destination is always
    /// a real station, and NET/ROM aliases such as `DRLNOD` or `EPINOD` ride in
    /// UI frames whose destination is genuinely an address, so neither rule may
    /// reach beyond the two shapes it knows.
    static func carriesDataRatherThanAStation(_ packet: Packet) -> Bool {
        guard packet.frameType == .ui else { return false }
        if let dataType = packet.info.first, micEDataTypes.contains(dataType) {
            return true
        }
        let destination = (packet.to?.call ?? "").uppercased()
        return destination.range(of: tocallPattern, options: [.regularExpression]) != nil
    }
}
