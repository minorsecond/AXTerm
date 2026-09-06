# Multi-Radio AXTerm

AXTerm is growing from one TNC to several: a Direwolf base today, an IC-705
next, TNCs reached over the internet after that. This document is the
contract for how that is modelled and what an operator with one radio must
never notice. It is written against the code as it stands; sections are
added as each layer lands.

## Vocabulary

**Radio** is the operator-facing word for the thing being managed — it is
what the operator has several of. **TNC** survives only where it literally
means the far end of a link: the single-radio status strings, and the
"Software" row that shows what a TNC called itself. Never "interface" or
"port" for the object: the KISS port is a *field* of a radio, and Direwolf
and BPQ operators already use "port" for that.

## The model

A **radio** is one TNC port on one link, operating under a callsign.

- `RadioID` (`AXTerm/Radio/RadioID.swift`) — an opaque UUID string. Not the
  host:port (a serial TNC has neither), not the callsign (two radios may
  share one), not the list position (radios get reordered). Minted once,
  kept in settings, stamped on history so it stays attributable after the
  radio is renamed.
- `RadioProfile` (`AXTerm/Radio/RadioProfile.swift`) — the settings for one
  radio: name, transport kind (`tcp` / `serial` / `ble`, spelled as the old
  `kissTransportType` scalar always spelled them), every transport's fields
  at once (switching TCP → serial → TCP keeps the host, as the Connection
  pane always did), Mobilinkd settings, TNC capabilities, and the fields the
  later layers act on: `kissPort`, `callsign` (empty = station callsign),
  `enabled`, `autoConnect`, `frequencyHz`, `archived`. Every field but the id
  decodes with a default, so a profile written by an older build loads
  under a newer one.
- **Radio ≠ link.** A link is a byte stream (`RadioProfile.linkKey`:
  `tcp://host:port`, `serial://path`, `ble://uuid`). One Direwolf with two
  channels is one link carrying two radios, told apart by the KISS port
  nibble. This is why the parser keeps the port (`KISSFrameParser.feedFrames`)
  and why every frame a session produces leaves on its session's channel
  (`AX25SessionManager.processActions`).
- `RadioIdentity.primaryID` — the fixed id of the radio a station had before
  it had several. Minted lazily and kept in defaults, like
  `WinlinkSyncDevice.identifier`, so the settings migration and the database
  migration that backfills old rows can each ask for it without ordering.

## Settings: the list and the mirror

`AppSettingsStore.radios` is the ordered list (`radios.v1`, JSON in
defaults). Removed radios are archived, not deleted, so rows that name them
keep a name. The **primary** radio is the first enabled one.

On the first launch after the update the list is absent and the one radio
the station had is read off the scalar settings (`lastHost`, `lastPort`,
`kissTransportType`, the serial, BLE and Mobilinkd keys, `tncCapabilities`),
named for its transport ("Direwolf" for TCP, the device for serial, the
peripheral for Bluetooth).

Those scalars are still what the engine reads. So the primary radio's
profile **mirrors into them, and they mirror back** — the same arrangement
`WinlinkSettings.gatewayLadder` uses for its top rung. Both directions are
guarded by equality checks and a re-entrancy flag, so a value that already
agrees is never rewritten and the two cannot chase each other. The writers
that still speak the old language (the engine's auto-gain telemetry, tests)
therefore land in the radio without knowing it exists. The mirror is
transitional: it goes once nothing reads the scalars.

Two radios cannot both hold one link and port (`RadioProfileIssue
.duplicateLink`), and two enabled radios answering as one address is flagged
(`.duplicateCallsign`) — legal on different frequencies, a hazard on the
same one. The Radios list says so under the rows.

## The Connection pane, and the Radios pane

`SettingsTab.radios` is one tab with two faces, and the face is decided by
`AppSettingsStore.hasMultipleRadios`.

**One radio**: the tab is called **Connection**, carries the cable icon, and
shows that radio's form directly — the same segmented transport picker, the
same per-transport content, the same link status and TNC identification the
Connection pane always had. No list, no back button, no name to edit, no
Remove. The only new thing is a quiet **"Add a second radio…"** row at the
bottom. Nothing says "radios" until the operator has two.

**Several radios**: the tab becomes **Radios**, and shows a list — status
dot, name, callsign · endpoint, drag to reorder, "Add Radio…" — with a form
per radio pushed over it: name, enabled, the transport, the link status, and
Remove (refused for the last radio: a station needs one). Deep links
(`SettingsRouter.navigate(to: .radios, radio:)`) land on the named radio's
form with the list beneath for the back button.

The form shows **only controls the code acts on**. The per-radio callsign,
KISS port and auto-connect are in the profile and appear as the layers that
give them effect land. A switch that changes nothing teaches the operator to
stop trusting switches.

On iOS the same two faces sit behind the More screen's row, which is likewise
"Connection" or "Radios" (`SettingsDestination.radios` / `.radio(id)`).

## The link layer

`RadioManager` (`AXTerm/Radio/RadioManager.swift`) owns one `LinkSession`
per byte stream and a table saying which radio each KISS port of each
stream belongs to.

- `LinkSession` (`AXTerm/Radio/LinkSession.swift`) is a `KISSLink` plus the
  parser that reassembles its frames. The parser lives with the stream and
  not with a radio because a KISS frame can be split across TCP reads, and
  the pieces belong to the stream before the finished frame's port says
  which radio it is for. The session also keeps the TNC's own facts — what
  it called itself, a Mobilinkd's battery and input level.
- `reconcile(radios, open:)` brings the links into line with the enabled
  profiles. A link still wanted is kept (a serial or Bluetooth one has its
  config applied in place, and its transport decides whether that needs a
  reconnect — Mobilinkd gains never do); a link no longer wanted is closed;
  a new one is opened. Two radios on one Direwolf share a link and differ by
  port. Opening reports "connecting" before the transport has said so, so a
  caller that connects and then reads the state is not shown the stale
  "disconnected".
- Inbound: a frame comes off a session with its port; the table names the
  radio; `RadioManager.ingest` publishes it as a `RadioIngest`. A frame on a
  port no radio claims is dropped, counted, and reported once per link and
  port (CLAUDE.md §4: logged, not dropped silently).
- Outbound: a frame carries its `radio` (`OutboundFrame.radio`, which
  replaced the always-zero `channel`); `RadioManager.send` looks up that
  radio's link and port. `AX25SessionManager.processActions` stamps every
  frame a session produces with the session's radio, so a UA answering a
  SABM heard on the second radio leaves by the second radio. Pinned end to
  end in `TwoRadioSessionTraceTests`.

`PacketEngine` no longer owns a link. It consumes `ingest`, stamps every
`Packet` with `radioID`, `kissPort` and the link's description, and keeps a
one-line summary for the surfaces that still show one status: the aggregate
status and the primary radio's host, port and TNC identity. `connect(host:
port:)`, `connectSerial` and `connectBLE` remain as shims that reconcile a
single overriding profile — the test harness and the old link-reuse tests
speak them — and do not write settings.

The session layer's dimension is the radio: `SessionKey.radio` (was
`channel: UInt8`, always 0) and `AX25Session.radio`. Every handler threads it
through, with `.primary` as the default so callers that predate radios still
compile. One peer heard on two radios is two sessions. Per-radio callsigns
are not yet in effect: every radio answers as the station callsign.

## What an operator with one radio must never notice

Every "only when there is more than one" decision hangs off one predicate,
`AppSettingsStore.hasMultipleRadios`. With one radio:

- the toolbar capsule shows the strings it always showed — "TNC: host",
  "TNC Connecting…", "TNC Disconnected", "TNC Failed" — and "TNC Settings…";
- the menu bar header and its Connect/Disconnect verbs are unchanged;
- the iOS status strip says exactly what it said, and reads the same aloud;
- no Radio column, no "· on <radio>" in session labels, no "on <radio>" in
  the packet status line;
- Settings shows the Connection pane it always showed — same name, same
  icon, same form — with one added row, "Add a second radio…".

These are pinned literally in `RadioPresentationTests`,
`TNCStatusStripTests`, `StatusItemControllerTests`,
`PacketFilterSummaryTests` and `SessionRecordLabelTests`.

## Landed so far

1. The KISS port survives deframing; session frames leave on their channel;
   the dead `NWConnection` receive path and `KISSTransport` are gone.
2. The radio model, the settings list with its mirror, and the Connection /
   Radios pane. The engine still holds one link and connects to the primary
   radio; the list says so while that is true.

3. The link layer: one `LinkSession` per byte stream, ports demuxed to
   radios, every packet and session bound to its radio, replies leaving by
   the radio that heard the call. All enabled radios connect.

Next: the radio dimension in storage (a migration that lets serial and
Bluetooth packets stop borrowing the TCP endpoint), per-radio callsigns,
cross-radio duplicate handling and per-radio link metrics, then the
services and the multi-radio UI. See `Docs/RoutingMetrics.md` for how link
quality will be kept per radio.
