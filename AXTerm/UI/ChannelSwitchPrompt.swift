//
//  ChannelSwitchPrompt.swift
//  AXTerm
//

import Foundation

/// What AXTerm asks before switching a radio between APRS and Packet
/// (retest 2026-10-10, finding 14). The switch changes what AXTerm does on
/// the radio, not the radio's frequency, so the question says the operator
/// has to retune it. The packet direction names no frequency: there is no
/// single packet channel.
nonisolated struct ChannelSwitchPrompt: Equatable {
    let title: String
    let message: String
    let confirmLabel: String

    init(radioName: String, to channel: RadioChannel) {
        switch channel {
        case .aprs:
            title = "Switch \(radioName) to APRS?"
            message = "AXTerm will send APRS on \(radioName) and stop answering packet calls on it. "
                + "It does not retune the radio: set it to your APRS frequency "
                + "(144.390 MHz in North America) yourself."
            confirmLabel = "Switch to APRS"
        case .packet:
            title = "Switch \(radioName) to Packet?"
            message = "AXTerm will use \(radioName) for packet sessions and stop sending APRS on it. "
                + "It does not retune the radio: set it to your packet channel yourself."
            confirmLabel = "Switch to Packet"
        }
    }
}
