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
                + "sessions are off. Switch it to Packet to connect.",
            radioName: RadioDetailView.title(for: radio))
    }

    /// The way out: the radio's Channel setting, as Settings sets it. Its
    /// beacon becomes an ID beacon and its packet services come back.
    static func switchToPacket(_ radio: inout RadioProfile) {
        RadioChannel.packet.apply(to: &radio)
    }

    /// What the Terminal shows above its controls while a connect is
    /// blocked: the reason and the radio Switch to Packet acts on. Shown in
    /// session mode until a link is up; broadcast is APRS's own business, and
    /// a link already open is left alone.
    struct Notice: Equatable {
        let text: String
        let radio: RadioID
        var radioName: String = ""
    }

    static func notice(block: ConnectFailure?, mode: TxConnectionMode,
                       sessionState: AX25SessionState?) -> Notice? {
        guard let block, case let .radioOnAPRSChannel(radio) = block.reason,
              mode == .connected, sessionState != .connected else { return nil }
        return Notice(text: block.detail ?? "This radio is on the APRS channel.", radio: radio,
                      radioName: block.radioName ?? "this radio")
    }

    /// Whether Connect is disabled: in session mode, while the radio is on
    /// an APRS channel. The operator could press it on the drive and see
    /// nothing happen (2026-10-09).
    static func blocksConnect(_ block: ConnectFailure?, mode: TxConnectionMode) -> Bool {
        block != nil && mode == .connected
    }
}
