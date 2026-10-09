import Foundation

/// Connected sessions stay off a radio on the APRS channel, a shared beacon
/// frequency (`RadioProfile.runsPacketServices`).
///
/// A station there refuses calls with DM, and on the APRS drive
/// (2026-10-09) the phone, its only radio on APRS, still sent an XID and two
/// SABMs to A (705), which refused them. The connect is stopped before
/// anything goes on the air, and the operator is told why with a way out.
nonisolated enum PacketChannelGate {

    /// Why a connect can't leave on `radio`, or nil when it can.
    static func connectFailure(for radio: RadioProfile?) -> ConnectFailure? {
        guard let radio, !radio.runsPacketServices else { return nil }
        return ConnectFailure(
            reason: .radioOnAPRSChannel(radio.id),
            detail: "\(RadioDetailView.title(for: radio)) is on the APRS channel, where connected "
                + "sessions are off. Switch it to Packet to connect.")
    }

    /// The way out: the radio's Channel setting, as Settings sets it. Its
    /// beacon becomes an ID beacon and its packet services come back.
    static func switchToPacket(_ radio: inout RadioProfile) {
        RadioChannel.packet.apply(to: &radio)
    }
}
