# Settings

How AXTerm's Settings are laid out, where each setting lives, and how the rest
of the app sends the operator to one.

Code: `AXTerm/Settings/` (`SettingsView`, `SettingsRouter`, `SettingsHome`,
`RadiosSettingsView`, `RadioDetailView`, `RadioTimingSection`,
`RadioRoleSections`, `PacketNodeSettingsView`, `APRSSettingsView`,
`AddRadioFlow`, `AddRadioSheet`, `FirstRunSetup`), the iOS list in
`AXTerm/iOS/AXTermiOSRootView.swift`.

## The rule

Every setting has exactly one home, and that home does not move when a second
radio is added.

A radio's page holds its hardware and identity: how it is reached, its TNC or
modem, the callsign it goes on the air with, its channel and its timing. What
the radio does on the air is on the service page for its channel, in a section
of its own: its APRS path and position beacon under APRS, its packet services,
digipeater and ID beacon under Packet Node. The operator sets up a role next to
the station-wide switches it depends on, and the radio page stays short.

Before this, an APRS radio was set up in three places: the channel and path on
the APRS page, the beacon on the radio's page, and the digipeater either on the
Transmission page (one radio) or the radio's own page (several). A station with
one radio and a station with two had different pages for the same thing.

`SettingsHome.entries` records the home of every setting the redesign touched,
by the key it is stored under (an `AppSettingsStore` key, `WinlinkSettings`'
grid square key, or `radio.` plus the `RadioProfile` field). Moving a control
means changing its entry; the stored key never changes, so existing settings
look the same after an upgrade (`SettingsUpgradeCompatibilityTests`).
`SettingsHomeTests` checks that no setting is registered twice and that every
control the Transmission page had now has a home.

The beacon's switch and interval are the exception. A radio has one stored
beacon, sent as a position beacon on an APRS channel and an ID beacon on a
packet channel, so these two appear in the radio's section on whichever page
its channel names. They are listed in `SettingsHome.byChannel` with a home on
each page, kept out of `entries`, and `SettingsHome.section(of:channel:)`
answers for a given channel. The beacon's kind is set by the channel and lives
with it.

## The sidebar

macOS, top to bottom:

- **Station**: General, Notifications
- **Radios**: Radios
- **Services**: APRS, Packet Node, BBS, Winlink
- **Maintenance**: Advanced, Link Debug

The iOS More list mirrors it: General under Station; Radios; APRS, Packet Node,
Mailbox and Winlink under Services; then the device's own settings and
Diagnostics. iOS has no Notifications, Advanced or Link Debug page; links to
those open Diagnostics or General (`SettingsDestination.init(_:)`).

There is no Transmission page. All of its controls are on Packet Node now: the
station-wide ones in their own sections, the per-radio ones (digipeater, ping,
the node announcement) in each packet radio's sections.

## General

- **Identity**: the station callsign, the base call without an SSID (see
  MultiRadio.md, "Station callsign and SSIDs").
- **Station position**: this device's location, an exact coordinate, an
  address lookup that fills the coordinate, and the grid square. This is the
  one grid square in the app. Winlink shows it read-only, and its "Fill Address
  From My Position" fills the postal address only. A "Use DM79lr" button beside
  the grid field works out the square from the position in use when that is
  better than a square.
- **Display**, **Online**, **System**.

## A radio's page

Radios is always a list, one radio or several. With one radio the Mac pane
opens straight onto that radio's page, with the list behind it for the back
button. The page is the same for the first radio and the fifth, titled with
the radio's name (or the name the app gives it: "Direwolf", the Bluetooth
device's name, the rig model).

Top to bottom:

1. **Connection**: name and enabled (with several radios), "Reached by" and the
   transport's fields; then the link's status with Connect or Disconnect, and
   the TNC's own sections: a Mobilinkd TNC4's audio and interface, or the sound
   modem's rig control, transmit level and radio setup.
2. **Identity**: the SSID under the station's base call, or another callsign.
   The picker shows the published APRS meaning of each SSID only on an APRS
   channel; a packet radio shows what its neighbors use an SSID for, or
   nothing (`SSIDConvention.family(for:)`).
3. **Channel**: APRS or Packet, a segmented control. It reads and writes
   `RadioProfile.aprsEnabled`, which stays the stored truth (`RadioChannel`).
   Under it, one row says what the service page holds for this radio
   (`RadioRoleSections.summary`: the beacon and path for an APRS radio, the
   services switched on for a packet radio) with "Open in APRS" or "Open in Packet Node", which
   lands on this radio's section there.
4. **Timing**: TX delay, persistence, slot time and TX tail.
5. **Remove Radio**, with several radios.

Switching the channel changes the beacon's kind with it and keeps everything
else, so a radio moved to APRS and back finds its ID beacon's text, its
services and its digipeater as it left them. It also moves the radio's
sections from one service page to the other. A radio moved to APRS for the
first time gets a position beacon that follows the station position and the
path `WIDE1-1,WIDE2-1` (see MultiRadio.md).

A radio whose stored beacon is not its channel's kind (an APRS position beacon
with APRS switched off, from before channels were one or the other) is left as
it was. Its beacon rows on the service page say what the radio sends and offer
the one change that matches it to the channel; nothing is migrated.

### Timing

One section on every radio, bound to `txDelayMs`, `persistence`, `slotTimeMs`
and `txTailMs`. The Mobilinkd and sound-modem sections no longer carry their
own copies. How the values reach the air depends on the transport
(`RadioProfile.timingDelivery`):

| Transport | Delivery | When |
|---|---|---|
| Sound modem | the modem uses them itself (`ModemLinkConfig`) | from the next transmission |
| Bluetooth LE TNC | `KISSLinkBLE` sends the KISS frames | on connect, and again when they change (`applyLive`) |
| Serial Mobilinkd | `KISSLinkSerial` sends them | on connect, and again when they change |
| Network TNC (Direwolf), plain serial TNC | only when "Send these to the TNC" is on (`sendsKISSTiming`, off by default); `RadioManager` sends them on the radio's KISS port | on connect, and again when they change |

With "Send these to the TNC" off, the four fields are dimmed and locked but
keep their values (`RadioTimingSection.fieldsEditable`).

While a radio's page is open the engine does not reconcile, so a half-typed
host does not reopen the link on every keystroke. Timing and a TNC4's levels
change nothing about the link, so they are still applied as they change
(`RadioManager.applyInPlace`); before, they waited until some later edit made
the engine reconcile, since closing the page reconciles only when a
transport changed.

A network or plain serial TNC was never sent timing, so the option is off by
default and such a TNC keeps the values it was configured with (direwolf.conf's
TXDELAY, PERSIST, SLOTTIME and TXTAIL). With the option on, Direwolf takes the
KISS values for that channel until it restarts. Each row's tooltip gives the
unit, what the value does and a typical value; the Icom IC-V8 needs a 500 ms TX
delay (MobilinkdTNC4.md).

## Each radio's sections

`RadioRoleSections` builds them, one view per page (`RadioAPRSSections`,
`RadioPacketSections`), each for one radio and with its own state (the symbol
picker, the last "Send one now" result). Every write re-applies the node
settings, as the radio page did. A radio switched off still gets its sections,
marked "off" in the header, so its page's link always lands somewhere; an
archived radio does not. Radios are in list order.

On the **APRS** page, one section per radio on an APRS channel, headed with
the radio's name and the callsign it goes on the air with: the **path**
(presets and advice) and the **position beacon** (on/off, symbol and overlay,
comment, position, ambiguity, compressed, a preview of the info field,
interval, Send one now). With no APRS radio, a note says so, with a button to
Radios.

On the **Packet Node** page, right after NET/ROM Node, three sections per radio
on a packet channel: its **services** (announce the NET/ROM node, with this
radio's alias when each radio is its own node; ping stations; answer mailbox
calls), its **digipeater** (on, fill-in, wide-area hops 0 to 7, aliases, dupe
window) and its **ID beacon** (text, via path, interval, Send one now). With no
packet radio, one note says so.

### Nothing connected-mode on an APRS channel

A radio on an APRS channel never runs a packet service, and the operator cannot
switch one on there (`RadioProfile.runsPacketServices`): no node announcing,
no pinging (the automatic pass skips the radio and a manual probe is refused,
`PingProber.mayProbe`), no mailbox, and no Winlink peer-to-peer answering. A
call that arrives on such a radio is refused at the link with DM, from the
address that was called, and an XID with P set gets DM too
(`AX25SessionManager.refusesInboundLinks`); a link the operator opened there
is left alone. The Winlink page names the radios a call can be answered on
and shows the switch off and locked when every radio is on an APRS channel.
The stored switches are not cleared, so a radio moved back to a packet
channel finds its services where it left them. Operator ruling, 2026-10-06.

"Send one now" needs the radio's link up. It reads the link from
`PacketEngine.radioSummaries`, the same state the Radios list shows.

### Per-radio services work with one radio too

The service switches used to appear only with two radios. They are now shown
for every packet radio under Packet Node, and
`SessionCoordinator.serviceRadios` obeys them with one radio: Ping stations
switched off on the only radio means no pinging. The node announcement and the
mailbox already read the switch with one radio.

APRS messages and the "who can hear me" query go out on the radios whose
channel is APRS when there are several, and on the one radio when there is
only one, whatever its channel, as before (`RadioChannel.aprsRadios`, read by
both `SessionCoordinator.connectedAPRSRadios` and the APRS page).

### Position beacon and the station position

"Station position" (stored as `APRSPositionConfig.useGPS`) sends the position
the map draws, from `StationPositionResolver.ownStation`: the exact coordinate
when one is set, else this device's fix when "This device's location" is on,
else the center of the grid square. Both shells install
`StationPositionResolver.beaconProvider` as the coordinator's
`aprsLocationProvider`. It used to read the device's last location or the
grid center and ignore the exact coordinate, and the iOS shell installed
nothing, so there such a beacon never went out.

"Fixed position for this radio" sends the radio's own latitude and longitude.
A position beacon with no position settings stored follows the station.

## Packet Node

Top to bottom:

- **NET/ROM Node**: run the node, auto-routing chain length, node alias,
  announce this station, node identity (with several radios), announce
  interval, transit routing. A "Runs on" line names the radios that carry the
  NODES broadcast.
- Each packet radio's sections (above).
- **Ping**: on/off, the hours, the hourly ceiling, spacing and per-station
  cooldowns, "also stations others are calling", the last eight probes and Ping
  Activity. A "Runs on" line names the radios that ping.
- **Link Layer**: T1, AX.25 2.2 negotiation, PACLEN, K and N2.
- **Adaptive Transmission**: on/off, status, and clearing what was learned. Its
  own copy of PACLEN, K and N2 went; they are the Link Layer's.
- **AXDP Protocol** and **File Transfers**.

The APRS page has **Messaging** (a "Runs on" line and auto-reply), then each
APRS radio's section. BBS (Mailbox on iOS) has a "Runs on" line for the radios
the mailbox answers on. None of the "Runs on" lines is a control: the switches
are in each radio's section.

## Deep links

`SettingsRouter.navigate(to: SettingsSection, radio:)` opens the page that
holds a section and scrolls to it. Pages are built on `SettingsForm`, which
wraps its `Form` in a `ScrollViewReader`; each landing section carries
`.id(SettingsSection)`. When `highlightSection` names one of the page's
sections, the page takes it (`consume`, which clears it so a later visit does
not jump) and scrolls it to the top on the next turn of the run loop.
`pendingRadio` names the radio whose page to push.

A link to `.aprsRadios` or `.packetRadios` with a radio lands on that radio's
section. The page passes `SettingsForm` a `RadioLanding`: when the form takes
that landing it also takes `pendingRadio` (`SettingsRouter.consumeRadio`) and
scrolls to the radio's section, whose id is `aprs.<radio id>` or
`packet.<radio id>` (`RadioRoleSections.landing`). A link with no radio, or
one naming a radio not on the page, lands on the first radio's section, or on
the note when there is none. Taking the radio there keeps it from opening in
the Radios pane on a later visit. The Radios pane also leaves a pending radio
alone once the tab has moved away from it, since "Open in APRS" names the
radio while the radio page is still showing. On iOS the shell's open action
takes the radio only for a link to Radios and leaves the rest to the page.

| From | Lands on |
|---|---|
| Sidebar radio's "Radio Settings…", toolbar "TNC Settings…" | that radio's page, Connection |
| Toolbar radios menu "Radio Settings…", iOS status strip | Radios (the only radio's page when there is one) |
| Position chip | General, Station position |
| Link Layer's "Open Radio Settings…" | the first radio's page, Connection |
| Packet Node's APRS note | Radios, the radio's Channel |
| A radio page's "Open in APRS" | APRS, that radio's section |
| A radio page's "Open in Packet Node" | Packet Node, that radio's services |
| The APRS page's "Radios…" (no APRS radio) | Radios |
| Compose banner, no callsign | first-run setup |

On iOS, `SettingsDeepLink.path` decides what happens to the More stack: nothing
when the page is already showing, back to a page already in the stack, pushed
onto the stack when it is on screen, and a fresh stack when the More tab was
behind another tab. It used to replace the stack every time.

## Add Radio

Add Radio… on the list opens a guided sheet (`AddRadioSheet`, state in
`AddRadioFlow`), on iOS as well:

1. **Connect**: name, "Reached by" and the transport's fields (the radio
   page's own views), and Test the Link.
2. **Channel**: APRS or Packet.
3. **Identity**: the SSID, with suggestions for the channel (0, 9 and 7 on
   APRS, the lowest free SSIDs on packet) and SSIDs other radios use marked.
4. **Basics**: on APRS the symbol, position beacon on/off and interval, and the
   path; on packet the node announcement (and this radio's alias when each
   radio is its own node), the mailbox and the digipeater (off).
5. **Done** switches the radio on and opens its page. The read-out says the
   rest of its role is under APRS or Packet Node.

Channel comes before Identity because the SSIDs worth suggesting depend on it.
The Basics step sets role settings on purpose: setup is a guided flow, and
these are the few a new radio needs before it is useful.

The radio is real from the first step, added switched off so nothing connects
while the operator is still choosing; Test the Link switches it on.
Cancel removes it (`AppSettingsStore.discardRadio`), or archives it if its link
came up during the test, because frames heard then may already be stored
against its id. Setting up an existing radio keeps a copy and Cancel restores
it.

## First-run setup

A station with no callsign is offered setup once (`FirstRunSetup.offersItself`,
never in a test instance): the callsign, the station position (the same
section General shows), then the radio. With one radio the last step offers
"Set Up <radio>…", which runs the Add Radio steps on that radio, or keeps it as
it is; "Add a Radio…" adds another. Skip Setup keeps what was entered and does
not offer setup again (`setup.firstRun.dismissed.v1`). The compose banner's
"Set Up…" opens it whenever the callsign is missing.

## Tests

- `SettingsHomeTests`: one home per setting, the Transmission controls' homes,
  hardware on the radio page and role on the service page, the beacon's two
  channel-dependent settings.
- `RadioRoleSectionsTests`: which radios get a section, where a link lands,
  the header and the radio page's summary line.
- `RadioChannelTests`: the Channel picker and `aprsEnabled`.
- `RadioServiceSwitchTests`: per-radio switches with one radio, "Runs on".
- `RadioTimingTests`: delivery per transport, what `RadioManager` sends.
- `BeaconStationPositionTests`: the beacon and the map agree.
- `SettingsDeepLinkTests`, `SettingsRouterRadioTests`: routing and the iOS stack.
- `AddRadioFlowTests`: Cancel and Done, SSID suggestions, first-run gating.
- `SettingsUpgradeCompatibilityTests`: a stored blob from the previous build.
- `SettingsSidebarPublishTests`: every page, the radio page on both channels
  with one and two radios, the APRS and Packet Node pages with a radio on each
  channel, a link to a radio's sections (the page takes the section and the
  radio), each Add Radio step and each first-run step, hosted off-screen with
  no "Publishing changes from within view updates" warnings.
