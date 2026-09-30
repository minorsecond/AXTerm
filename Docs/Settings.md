# Settings

How AXTerm's Settings are laid out, where each setting lives, and how the rest
of the app sends the operator to one.

Code: `AXTerm/Settings/` (`SettingsView`, `SettingsRouter`, `SettingsHome`,
`RadiosSettingsView`, `RadioDetailView`, `RadioTimingSection`,
`PacketNodeSettingsView`, `APRSSettingsView`, `AddRadioFlow`, `AddRadioSheet`,
`FirstRunSetup`), the iOS list in `AXTerm/iOS/AXTermiOSRootView.swift`.

## The rule

Every setting has exactly one home, and that home does not move when a second
radio is added.

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

There is no Transmission page. Its per-radio parts went to the radio page and
its station-wide parts to Packet Node.

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
3. **Channel**: APRS or Packet, a segmented control. It reads and writes
   `RadioProfile.aprsEnabled`, which stays the stored truth (`RadioChannel`).
4. On an **APRS** channel: the **APRS path** (presets and advice) and the
   **Position beacon** (on/off, symbol and overlay, comment, position,
   ambiguity, compressed, a preview of the info field, interval, Send one now).
   On a **Packet** channel: **Services on this radio** (announce the NET/ROM
   node, with this radio's alias when each radio is its own node; ping
   stations; answer mailbox calls), the **Digipeater** (on, fill-in, wide-area
   hops 0 to 7, aliases, dupe window) and the **ID beacon** (text, via path,
   interval, Send one now).
5. **Timing**: TX delay, persistence, slot time and TX tail.

Switching the channel changes the beacon's kind with it and keeps everything
else, so a radio moved to APRS and back finds its ID beacon's text, its
services and its digipeater as it left them. A radio moved to APRS for the
first time gets a position beacon that follows the station position.

A radio whose stored beacon is not its channel's kind (an APRS position beacon
with APRS switched off, from before channels were one or the other) is left as
it was. The beacon section says what the radio sends and offers the one change
that matches it to the channel; nothing is migrated.

### Per-radio services work with one radio too

The service switches used to appear only with two radios. They are now on
every radio's page, and `SessionCoordinator.serviceRadios` obeys them with one
radio: Ping stations switched off on the only radio means no pinging. The node
announcement and the mailbox already read the switch with one radio.

APRS messages and the "who can hear me" query go out on the radios whose
channel is APRS when there are several, and on the one radio when there is
only one, whatever its channel, as before (`RadioChannel.aprsRadios`, read by
both `SessionCoordinator.connectedAPRSRadios` and the APRS page).

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

The station-wide half of the packet services:

- **NET/ROM Node**: run the node, auto-routing chain length, node alias,
  announce this station, node identity (with several radios), announce
  interval, transit routing. A "Runs on" line names the radios that carry the
  NODES broadcast.
- **Ping**: on/off, the hours, the hourly ceiling, spacing and per-station
  cooldowns, "also stations others are calling", the last eight probes and Ping
  Activity. A "Runs on" line names the radios that ping.
- **Link Layer**: T1, AX.25 2.2 negotiation, PACLEN, K and N2.
- **Adaptive Transmission**: on/off, status, and clearing what was learned. Its
  own copy of PACLEN, K and N2 went; they are the Link Layer's.
- **AXDP Protocol** and **File Transfers**.

The APRS page keeps messaging auto-reply and a "Runs on" line. BBS (Mailbox on
iOS) gains a "Runs on" line for the radios the mailbox answers on. None of
these lines is a control: the switches are on the radios' pages.

## Deep links

`SettingsRouter.navigate(to: SettingsSection, radio:)` opens the page that
holds a section and scrolls to it. Pages are built on `SettingsForm`, which
wraps its `Form` in a `ScrollViewReader`; each landing section carries
`.id(SettingsSection)`. When `highlightSection` names one of the page's
sections, the page takes it (`consume`, which clears it so a later visit does
not jump) and scrolls it to the top on the next turn of the run loop.
`pendingRadio` names the radio whose page to push.

| From | Lands on |
|---|---|
| Sidebar radio's "Radio Settings…", toolbar "TNC Settings…" | that radio's page, Connection |
| Toolbar radios menu "Radio Settings…", iOS status strip | Radios (the only radio's page when there is one) |
| Position chip | General, Station position |
| Link Layer's "Open Radio Settings…" | the first radio's page, Connection |
| Packet Node's APRS note | Radios, the radio's Channel |
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
5. **Done** switches the radio on and opens its page.

Channel comes before Identity because the SSIDs worth suggesting depend on it.

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

- `SettingsHomeTests`: one home per setting, the Transmission controls' homes.
- `RadioChannelTests`: the Channel picker and `aprsEnabled`.
- `RadioServiceSwitchTests`: per-radio switches with one radio, "Runs on".
- `RadioTimingTests`: delivery per transport, what `RadioManager` sends.
- `BeaconStationPositionTests`: the beacon and the map agree.
- `SettingsDeepLinkTests`, `SettingsRouterRadioTests`: routing and the iOS stack.
- `AddRadioFlowTests`: Cancel and Done, SSID suggestions, first-run gating.
- `SettingsUpgradeCompatibilityTests`: a stored blob from the previous build.
- `SettingsSidebarPublishTests`: every page, the radio page on both channels
  with one and two radios, each Add Radio step and each first-run step, hosted
  off-screen with no "Publishing changes from within view updates" warnings.
