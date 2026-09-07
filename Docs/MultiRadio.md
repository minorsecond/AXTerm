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

## Settings: the list

`AppSettingsStore.radios` is the ordered list (`radios.v1`, JSON in
defaults) and the only record of how the station's TNCs are reached.
Removed radios are archived, not deleted, so rows that name them keep a
name. The **primary** radio is the first enabled one; the surfaces that
still show a single connection (the one-radio capsule, the menu bar
header, the iOS strip, Sentry's connection tags, the diagnostics export)
read `settings.primaryRadio`.

On the first launch after the update the list is absent and the one radio
the station had is read off the old single-connection keys (`lastHost`,
`lastPort`, `kissTransportType`, the serial, BLE and Mobilinkd keys,
`tncCapabilities`), named for its transport ("Direwolf" for TCP, the device
for serial, the peripheral for Bluetooth), and `radios.v1` is written at
once. That read happens exactly once: nothing writes the old keys any more
and nothing reads them after the list exists. They are left in place so a
downgrade still finds its connection. (An earlier build of this branch kept
the two in step both ways — the "mirror"; it went once the last reader of
the scalars was moved to the list.)

Writers that used to set a scalar set the radio: the TNC4's auto-gain
telemetry lands in `mobilinkdInputGain` of every radio on that link through
`settings.updateRadio`, which is a no-op when the value already agrees.

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
compile. One peer heard on two radios is two sessions.

## Per-radio callsigns

Each radio operates as an address: its own callsign+SSID if the operator gave
it one (`RadioProfile.callsign`), else the station callsign. Two radios on
one licence are two stations on the air — an HF and a VHF station, say —
and a remote station may need to reach one in particular.

- `AX25SessionManager.localAddresses` holds the addresses that differ from
  the station callsign; `localAddress(for:)` answers for every radio.
  Outbound sessions open under the radio's address, `answers` accepts every
  radio's address, and the DM for a stranger's poll comes from the address
  of the radio that heard it. `setLocalAddresses` ends the sessions of a
  radio whose address changed — a session is bound to the address it
  opened under — and no others.
- `SessionCoordinator` watches the radio list and the station callsign
  through `appSettings` and keeps the manager's addresses current. It also
  keeps `radioOwners`: for each address exactly one radio operates as, that
  radio. The station callsign, shared by every radio without its own, is
  deliberately not owned.
- **The owner rule.** A frame addressed to an address one radio owns runs
  on that radio and is answered by it, whichever link heard it: two radios
  on one frequency both hear the call, and the one it was for replies. A
  frame to a shared address runs on the radio that heard it. Pinned end to
  end in `TwoRadioSessionTraceTests`.
- The digipeater repeats frames addressed to the hearing radio's callsign
  as well as the station's.

The Identity section of a radio's form appears only when there is another
radio to differ from; with one radio the station callsign under General is
the whole story. The Radios list flags two enabled radios answering as one
address — legal on different frequencies, a collision on the same one.

## Two radios on one frequency

Radios may share a channel — a portable rig beside the base on 2 m — and then
both hear every frame. Two things follow, and the station's count of the
world must not double for either.

- **One transmission, one packet.** `CrossRadioDedup`
  (`AXTerm/AX25/CrossRadioDedup.swift`) keys on the exact AX.25 bytes. A
  second radio's copy inside 1.5 s is folded: the packet is not logged
  again, no airtime is added, and — the reason this exists — the copy never
  reaches the per-radio duplicate tracker, whose two-second retry window
  would have scored it as a *failed delivery* and collapsed df toward 0.5 on
  a perfectly delivered link. The station is marked heard on the second
  radio too (`Station.perRadio`, `heardOn`). The window sits between the
  ingestion-dedup window (0.25 s) and the retry window (2 s), so a fold can
  never be mistaken for either; a digipeated copy differs by its H bits and
  is rightly two packets. Off with one radio.
- **Own echo.** Our transmission on one radio is heard by the other.
  `StationIdentityMonitor.classifyReceived` judges a received frame from any
  address this station operates as — the station callsign and every radio's
  own — as `.foreign`, `.ownEcho` (a frame we sent, heard straight back) or
  `.collision`. An echo is logged (`Packet.isOwnEcho`) so the operator can
  see the radios share a channel, but it is counted for no station, fed to
  no route inference and observed as no network path; its airtime was
  counted when it was sent. The digipeated copy of our own frame stays
  foreign, as before: that is what the digipeater put on the air.

A folded copy is still the second radio's evidence: it is fed to route
inference as a packet on that radio, where the metrics below keep it on
that radio's entry and no other — and it never reaches the retry tracker,
which is per radio and has not seen these bytes.

## Per-radio link metrics

A delivery probability is a property of a path between two antennas on one
band at one power. Two of our radios hearing the same station are two
links, and a clean one and a marginal one must not average into a mediocre
figure that misroutes both (CLAUDE.md §8: evidence-based; `WinlinkSyncPolicy
.attributed`: "measured from one place with one antenna").

- `LinkQualityEstimator` keys by `LinkKey {radio, from, to}`; df, dr, ETX,
  dups, recency and the adaptive TTL are all per radio. `linkQuality(from:
  to:radio:)` defaults to the primary so callers that predate radios keep
  their meaning; `radios(from:to:)` lists the radios that have measured a
  link. `LinkStatRecord.radioID` rides through export and import.
- `NetRomRouter` keys neighbours by `NeighborKey {radio, call}` and routes
  by (destination, next hop, radio). The same next hop on two radios is two
  ways in; `candidateRoutes` lists both and `bestRouteTo`'s hysteresis
  holds (next hop, radio). Hearing an origin on one radio refreshes only the
  routes learned through it on that radio. `radio(forNeighbor:)` names the
  radio a neighbour is best heard on, and NET/ROM datagrams to it leave by
  that radio.
- **Deterministic tie-breaks** (CLAUDE.md §9) gained the radio as their last
  term: `RadioID.deterministicOrder` puts the primary radio first, then
  orders by identifier, so the same tables always yield the same choice.
- `NetRomIntegration` keeps one duplicate tracker per radio — a retry is a
  retransmission the *same* receiver heard again — and processes a NODES
  broadcast against the radio it arrived on. Passive inference carries the
  radio through its evidence to the routes it publishes.
- Storage: `netrom_neighbors`, `netrom_routes` and `link_stats` are keyed
  by radio (`PRIMARY KEY (radioID, call)`, `(destination, origin, radioID)`,
  `(radioID, fromCall, toCall)`). `NetRomPersistence` rebuilds a table from
  before the key change on open, every row attributed to the primary radio —
  SQLite cannot change a key in place. Migration v31 adds `radioID` to
  `link_quality_history`, so a link's history is per radio like its present.

The one node identity, the ping budget shared by radios on one frequency,
and the Auto radio for a connect are the next layer.

## Storage

Migration v30 (`DatabaseManager.addRadioColumns`) adds the radio to the
rows a radio makes: `packets.radioID` (with `kissPortNibble` and
`linkDescription`), `terminal_sessions.radioID`, `bbs_calls.radioID`. Added
with a default rather than by rebuilding: every row that existed belonged
to the one radio the station had, `RadioID.primary` — the constant
`"radio-primary"`, fixed so the settings migration and the database
migration agree without asking each other — and SQLite fills the default in.
A rebuild of `packets` would rewrite the largest table in the file for no
gain.

`packets.kissHost`/`kissPort` stay as they were, but a serial or Bluetooth
frame now stores an empty host and port 0, which `KISSEndpoint`'s failable
initialiser reads back as "no TCP endpoint". Until this migration such a
frame was stamped with the settings' TCP address — a lie kept only because
the columns were NOT NULL and the record initialiser threw on anything
else. `PacketRecord.init(packet:)` no longer throws and
`SQLitePacketStore.save` no longer requires an endpoint.

Tables nothing reads by radio yet — link-quality history, the NET/ROM
neighbour and route tables — are left alone until the phase that keys them
by radio, so schema and code land together.

## Services across radios

Every station-wide service runs on every radio unless the operator switches
it off for one. The switches live on the radio profile — `sendsBeacons`,
`pings`, `announcesNode`, `answersMailbox` — all on by default, shown only
when there are two radios. `SessionCoordinator.serviceRadios(_:)` is the one
rule: with one radio it returns that radio, connected or not, exactly as
before radios existed; with several it returns the enabled radios that have
the service on and whose link is up.

**Stagger.** When one announcement leaves several radios, the k-th radio
waits k × 2 s (`SessionCoordinator.radioStagger`). Two radios on one
frequency would otherwise key up together and collide with themselves; on
different frequencies the delay costs nothing. Beacons and NODES both use it.

**Beacons** leave each beaconing radio from that radio's own callsign. The
console line gains " on IC-705, Base" only when several radios carried it.

**NODES and the node identity.** `netRomNodeIdentity` is operator-selectable:

- `unified` (default, BPQ's NODECALL over several PORTCALLs): the station
  callsign and alias are the node. Every announcing radio sends the same
  payload under its own L2 callsign, and a connect request for the node is
  accepted on any radio. The console reads "Announced this station as
  EPINOD on 2 radios."
- `perRadio`: each radio's callsign is its own node with its own alias
  (`RadioProfile.netRomAlias`, falling back to the station alias). The
  endpoint answers as the node that was called
  (`NetRomEndpoint.additionalLocalNodes`; an inbound circuit's origin is
  the address the CONREQ named), and each alias answers plain AX.25
  connects too. The nodes do not forward to each other; the setting says so.

The driver asks the coordinator for its `announcements()` —
`[(radio, node, alias)]` — so the identity rule lives in one place and
the driver only encodes what it is given.

**Ping.** A candidate carries the radio that heard it most recently among
the pinging radios, and the probe leaves as that radio's callsign; the DISC
escalation follows it. A station heard only on a radio whose pinging is off
is not a candidate. The hourly budget stays station-wide.

**Mailbox.** `PersonalBBSListener.servesThisRadio` refuses a call that
arrived on a radio with `answersMailbox` off, and says which switch to look
at. The mailbox itself is one mailbox.

**Winlink.** `WinlinkSettings.preferredRadioID` names a radio for Connect &
Exchange; empty is Auto. P2P answers stay on the radio the call came in on.

**Terminal.** The connect bar's radio is Auto unless the operator picks one;
a session's radio is fixed when it opens and data follows it, whatever the
picker says later.

### Auto

`RadioSelector` picks the radio for a connect left on Auto and says why in
one sentence the connect bar shows verbatim. It ranks what the radios
already know about the *first hop* — the first digipeater, or the
destination — read off the same per-radio evidence as the Stations list:

1. A radio that heard the first hop within that link's own TTL, lowest ETX
   first; readings within 0.05 are equal and the more recent hearing wins.
2. Otherwise the radio that heard it most recently, past TTL.
3. Otherwise the radio a NET/ROM route to the destination was learned on.
4. Otherwise the first connected radio in the operator's list.

Ties fall to the operator's order, so the same inputs always pick the same
radio. A radio that is not connected is never chosen, and the sentence
says so: "Auto → IC-705: heard K0NTS-1 there 4 min ago, ETX 1.2. Base last
heard it 3 h ago, past its TTL."

## The universal view

One set of views; the radio is a dimension of the data, never a mode of the
app. Every radio's traffic arrives interleaved in the Packets table, the
console and the map, each row attributable by its Radio column or the
station's "heard on" list. That is the default and the only state a
one-radio station is ever in.

The sidebar's **Radios** section (macOS, `hasMultipleRadios` only) lists
every radio with its status dot, callsign, RX/TX lights and a mini switch.
The switch is *visibility, not power*: `PacketEngine.hiddenRadioIDs` is a
set, empty by default, kept per device like the map's layer toggles. A
hidden radio still receives, still counts, still answers — it is only not
drawn. The set applies in one place, `PacketFilter.filter(hiddenRadios:)`,
so the Packets table and everything built on it agree; the map hides a
station only when *every* radio that heard it is hidden
(`PacketEngine.isVisible`), so a station heard on both radios stays one
dot, and says so in a footnote under Layers. The Packets status line reads
"2 of 3 frames · on IC-705" while a radio is hidden, and Show Everything
clears the radios along with the filters. "All Radios" above the rows
turns every switch back on.

The console is not filtered by radio: a terminal line is a conversation,
and its session already names its radio in the tab ("K0NTS-1 · on
IC-705"). The iOS shell shows the Radio column and the per-radio strip but
has no sidebar, so no switches.

**Status surfaces** with several radios — every one of them pinned to its
one-radio string by test:

- Toolbar capsule: one 8 pt dot per radio (help: name, status, endpoint,
  callsign), aggregated RX/TX lights, "Radios: 2 connected" / "Radios: 1 of
  2" / "Radios Disconnected", a menu section per radio with Connect /
  Disconnect / Cancel and the endpoint, Connect All / Disconnect All, and
  Radio Settings….
- Menu bar: the header counts ("1 of 2 radios connected · 812 packets"),
  ⌘K reads Connect All / Disconnect All, and each radio has a submenu.
- iOS strip: one dot per radio; the line names the one radio that needs
  attention ("IC-705 not connected") or counts them.
- Packets: a Radio column after Time ("which radio decoded this frame, not
  which the sender used"); on iOS the row's footer says "· IC-705".
- Stations rows: "12 pkts | 14:02 | IC-705, Base", most recent first.
- Routes: the radio's name under the neighbour's callsign and the route's
  next hop, because evidence on another radio is a separate entry.
- BBS callers: "on IC-705" beside the time.
- Terminal tabs and history: " · on IC-705".

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

4. Storage: migration v30 puts the radio on packets, terminal sessions and
   mailbox calls; serial and Bluetooth packets stop borrowing the TCP
   endpoint.

5. Per-radio callsigns: each radio operates as its own address, and a call
   to an address one radio owns is answered by that radio whichever link
   heard it.

6. Two radios on one frequency: one transmission is one packet, and our
   own echo is nobody's evidence.

7. Per-radio link metrics: link quality, neighbours and routes keyed by
   radio, with the radio as the last deterministic tie-break; storage keyed
   to match.

8. Services across radios: per-radio switches for beacons, ping, NODES and
   the mailbox; staggered announcements; both node identities; the Auto
   radio and its sentence; Winlink's preferred radio; the terminal's radio.

9. The universal view: the sidebar's radios and their visibility switches,
   the Radio column, the counting capsule, menu bar and iOS strip, the
   radio named on stations, routes, callers and terminal tabs — all hidden
   until a second radio exists.

10. The old single-connection keys retired: read once on the first launch,
    never written again; every surface reads `primaryRadio`. The rig's
    `dual` profile proves both hubs and all three nodes.

11. A radio without a TNC: the built-in sound modem (`RadioTransportKind
    .modem`), audio through a sound device and PTT and frequency over CI-V,
    first for the IC-705 over USB. It is a `KISSLink` like the others, so
    `LinkSession`, the demux, the engine and every surface above them are
    unchanged; its link key is the audio pair, and the radio's own frequency
    and name become facts on the profile. See [SoundModem.md](SoundModem.md).

Next: nothing planned. Deferred on purpose — shared ping budgets via
channel-group detection, cross-radio L3 forwarding, a console lens by
radio, iOS visibility switches.
