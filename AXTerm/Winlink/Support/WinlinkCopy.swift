import Foundation

/// Centralized user-facing copy for the Winlink feature (labels and
/// `.help()` tooltips), following the `GraphCopy` pattern. Tooltips
/// explain *why* a value is what it is, per CLAUDE.md §11.
nonisolated enum WinlinkCopy {

    // MARK: - Mailbox

    static let unreadBadgeTooltip = "Unread messages in your Winlink inbox. New mail arrives when you run a mail exchange with a gateway."

    static let deliveryStateTooltip = """
    Delivery state of this message:
    • Draft — editable, not yet queued
    • Queued — frozen, will be offered at the next exchange
    • Sending — proposed to the gateway in the current session
    • Sent — accepted by a gateway and handed to the Winlink network
    • Failed — the gateway rejected it (see the error); it stays in the Outbox
    • Received — inbound mail delivered to you
    """

    static let connectExchangeTooltip = """
    Connects to the selected RMS gateway and performs a full B2F mail
    exchange: queued Outbox messages are proposed and sent, then the
    gateway delivers any mail waiting for your callsign. An empty Outbox
    still polls for incoming mail.
    """

    static let abortExchangeTooltip = "Politely ends the running exchange (sends FQ and disconnects). In-flight messages return to the Outbox."

    static let composeTooltip = "Compose a new Winlink message. Addresses may be callsigns (K0EPI) or internet email (someone@example.com)."

    static let attachmentBudgetTooltip = """
    Winlink limits a message (body + attachments, before compression) to
    about 120 kB. Over packet radio at 1200 baud, every 10 kB takes
    roughly two minutes of airtime — keep attachments small.
    """

    // MARK: - Stations

    static let stationDistanceTooltip = """
    Great-circle distance from your grid square to the gateway's reported
    grid square, from the Winlink CMS proximity service. Set your grid
    square in Settings → Winlink.
    """

    static let stationFrequencyTooltip = "The gateway's published operating frequency. Tune your radio here before connecting."

    static let stationLastSeenTooltip = """
    When the gateway last reported to the Winlink CMS. A stale timestamp
    can mean the station is off the air — prefer recently seen gateways.
    """

    static let stationRefreshTooltip = """
    Fetches nearby packet-mode RMS gateways from the Winlink CMS
    (api.winlink.org) for your grid square and distance limit. Requires
    internet access; results are cached for offline use.
    """

    static let setGatewayTooltip = "Use this station as the mail gateway for Connect & Exchange."

    // MARK: - Catalog

    static let catalogTooltip = """
    The Winlink catalog lists data products (weather bulletins, forecasts,
    news…) you can request over the air. Selecting items queues a request
    message to INQUIRY; the products arrive as ordinary mail at a later
    exchange.
    """


    static let catalogRefreshTooltip = """
    Downloads the current catalog index from the Winlink CMS over the \
    internet, which needs a web-services access key. Without one, request \
    the index by radio instead: a LIST inquiry to INQUIRY comes back as \
    mail and fills the same cache.
    """

    // MARK: - Settings

    static let gridSquareTooltip = "Your Maidenhead locator (e.g. DM79lr). Used to find nearby RMS gateways and compute distances. 4, 6, or 8 characters."

    static let antennaHeightTooltip = "How far your antenna is above the ground beneath it \u{2014} not above sea level, which the terrain data already supplies. This is the single number that most often decides whether a path is workable: 60% Fresnel clearance over 13 km at 145 MHz needs roughly 49 m, and the same path from 10 m clears about 9% of the zone. Height, not gain, is what terrain analysis uses."

    static let assumedHeightTooltip = "Used for any station whose height nobody has recorded \u{2014} which is most of them, since neither the licence directory nor the Winlink CMS carries antenna height. Record a real one on a station's page when you know it. Forecasts built on this assumption say so."

    static let passwordTooltip = """
    Your Winlink account password, used for secure login (;PQ/;PR
    challenge–response) when connecting to gateways. Stored in the macOS
    Keychain, never in preferences.
    """

    static let apiKeyTooltip = """
    Winlink web-services access key for the station list and catalog.
    Leave empty to use the built-in community key; set your own if you
    have one from the Winlink team. Stored in the Keychain.
    """

    static let transportTooltip = """
    How mail exchanges connect:
    • Packet (AX.25) — over your TNC to an RMS gateway on the air
    • Telnet — direct internet connection to the Winlink CMS (no radio);
      useful for testing and when you're away from the station
    """
}
