# The iOS and iPadOS Port

AXTerm on iPhone and iPad — the same app, not a companion.

Status: **complete.** The terminal, the packet table, the Metal network
graph, the analytics dashboard, NET/ROM routes, mail, maps, settings and the
whole protocol core all build and run on iOS and iPadOS. What remains
macOS-only is the macOS shell itself — windows, menus, the AppKit table
implementation — and serial ports, which iOS does not have.

---

## 1. Why a port rather than a companion

The measurement that decided it: of 307 Swift files in the app target, only
32 touched AppKit or a macOS-only framework — and **none** of them were in
`AXTerm/AX25`, `Winlink/Protocol`, `Winlink/Session` or `Winlink/Store`.

The decoder, the routing inference, the B2F stack, LZHUF, the store and the
migrations are plain Swift that has never known what a window is. A separate
mail-only companion would have meant maintaining a second copy of the part
that must never diverge — the protocol — to avoid porting the part that is
merely inconvenient: the shell.

So both targets compile the same folder, and the iOS exclusion list holds only
the macOS shell and the capabilities iOS lacks.

---

## 2. The platform seam

`AXTerm/Platform/` names every difference once, so call sites read the same on
both platforms and the list of genuine differences stays short enough to see.

### `Platform.swift`

Type aliases (`PlatformColor`, `PlatformFont`, `PlatformImage`), semantic
colors whose names differ (`platformSeparator`, `platformCardBackground`,
`platformTertiaryLabel`, …), `PlatformPasteboard`, `PlatformScreen.scale`,
`PlatformSound`, and control idioms — `platformCheckboxToggle()` renders a
checkbox on macOS and a switch on iOS, because a checkbox on a touch screen
is a tap target three times too small.

`PlatformIdiom` reports *capability*, not screen size:
`supportsSerialPorts`, `supportsMultipleWindows`, `supportsHover`. Layout
differences belong to size classes, which adapt to a Mac window dragged
narrow as well as to a phone.

### `Explanation.swift` — the one that mattered

CLAUDE.md §11 requires every advanced metric to explain **why** it is what it
is. On macOS that has always been `.help()`.

**`.help()` compiles on iOS and does nothing.** Porting as-is would have
silently deleted every derivation explanation on the platform where the
operator is most likely standing in a field making a decision from a number
they cannot interrogate — and nothing in the build would have warned anybody.

So explanations now go through `.explain(_:)`: a tooltip where there is a
pointer, a tap-to-reveal popover where there is not, with a faint `info.circle`
marking explainable values on touch. Same text, same obligation, reachable
either way.

### `PlatformFileExport.swift`

The platforms disagree about more than spelling. A Mac has a save panel that
returns a destination; iOS has no filesystem the app may write into on the
user's behalf, so the file goes through a document exporter the user drives.
`.exportFile($binding) { error in }` covers both, and failure is never silent
— an attachment may be the only copy of something that cost airtime.

The iOS exporter's `ExportableFileDocument` has to declare every type it is
asked to write. It used to declare only `.data` while the exporter was handed
`.jpeg` or `.pdf`. It now declares `ExportableFile.exportableTypes` (the types
Winlink traffic carries), and `exportContentType` falls back to `.data` for
anything not on that list, keeping the file's own name.

---

## 3. What the iOS app has

`AXTerm/iOS/` holds the shell — a `TabView` rather than the Mac's sidebar,
because on a handheld the sections are peers the operator flips between
one-handed. The tabs are the same `NavigationItem` cases the Mac sidebar uses.

| Tab | Built from |
|---|---|
| Terminal | `TerminalView` — the Mac's own, including the compose bar, the routing control and file transfers. See "File transfers on iOS" below. |
| Packets | `PacketTableTouchView`, written for a narrow screen; the inspector is the Mac's `PacketInspectorView` in a sheet. |
| Mail | `WinlinkMailboxScreen` wrapping the Mac's `WinlinkMailboxViewModel`, `WinlinkMessageList` and `WinlinkMessageDetail` in a `NavigationSplitView` — three columns on iPad, a stack on a phone, without being told which it is. |
| Map | `StationsMapView` — the Mac's own, including offline tiles. |
| More | Analytics (Metal graph and dashboard), NET/ROM routes, Winlink settings, connection, transmission, diagnostics. Things opened deliberately rather than lived in, so they sit one tap deeper instead of pushing the terminal off a five-tab bar. |

Verified running on an iPad Pro simulator.

### The Metal network graph on touch

The graph is the one surface where the platforms differ in *kind*, not
spelling: a Mac has a hovering pointer, a scroll wheel, a right-click and
modifier keys; a touch screen has direct manipulation and none of those.

`GraphInput.swift` names the vocabulary once. `GraphInputModifiers` replaces
`NSEvent.ModifierFlags` (and picks up hardware-keyboard modifiers on an iPad
with a Magic Keyboard, so shift-to-multi-select still works). `GraphContextMenu`
models the node actions as data, so macOS renders them as an `NSMenu` and iOS
as a SwiftUI popover from a long press — the touch equivalent of a right-click.

One finger drags the camera, pinch zooms, tap selects, long press opens the
node's actions. All of the graph's actual behavior — hit testing, selection,
camera — stays in one coordinator that neither platform reimplements.

### File transfers on iOS

Packet file transfers (AXDP and YAPP) work the same as on the Mac, with
these differences, all covered in `Docs/PacketFileTransfer.md`:

- Received files go to `Documents/AXTerm Transfers`, which the Files app
  shows under AXTerm once the target declares `UIFileSharingEnabled` and
  `LSSupportsOpeningDocumentsInPlace`. They used to go to the container's
  Downloads folder, which nothing outside the app can open.
- A finished file offers Share and Quick Look instead of Show in Finder.
- Picked files are copied while their security scope is held and the scope
  is released at once; a picker that fails says so in an alert.
- On iPad, files dropped on the terminal from Files or Photos are loaded as
  file representations, several at a time. An iPhone is told to tap +.
- The Send File and offer sheets size to the device.
- Offers are prompted for from the root view over whichever tab is showing,
  and post a notification when the app is in the background.

### Transport on iOS

`KISSLinkNetwork` (NWConnection) works as-is against Direwolf or LinBPQ over
WiFi. `KISSLinkBLE` builds for iOS too, and the target carries the Bluetooth
usage string it needs (added 2026-09-29), but it hasn't been tried on a device.
It runs in the foreground only; there is no background Bluetooth mode. See
`Docs/MobilinkdTNC4.md`.

---

## 4. Still macOS-only

Everything left is either the macOS shell or a platform capability iOS lacks.
There is no remaining porting backlog.

**The macOS shell** — iOS has its own in `AXTerm/iOS/`
- `AXTermApp`, `AXTermAppDelegate`, `ContentView`, `AXTermCommands`,
  `MenuBarView`, `Settings/SettingsView`, `Info.plist`
- `Winlink/UI/WinlinkMailView` — superseded on iOS by `WinlinkMailboxScreen`

**The AppKit packet table** — iOS uses `PacketTableTouchView`
- `PacketNSTableView`, `PacketTableCoordinator`, `PacketTableNSTableView`,
  `RowSelectionCaptureView`

`NSTableView` is what keeps a live packet stream smooth on macOS; `List` gives
the same virtualization on iOS for free. Wrapping the AppKit table would have
bought nothing and cost a second implementation. What *is* preserved exactly
is the behavior a naive list lacks: follow the newest packet while the
operator is at the bottom, stop the moment they scroll away to read
something, and offer a way back.

**Capabilities iOS does not have**
- `Transmission/KISSLinkSerial` — no IOKit, no user-accessible USB serial.
  `SerialPortDiscovery` *does* build for iOS and returns an empty list, and
  `PacketEngine.connectUsingSettings()` checks
  `PlatformIdiom.supportsSerialPorts` and takes the network path instead.
- `Transmission/AppDelegate+Diagnostics`,
  `AX25DiagnosticLogger+FileLogging` — macOS app-delegate diagnostics
- `Settings/GeneralSettingsView` uses `SMAppService` for launch-at-login,
  guarded by `#if os(macOS)`; iOS has no login items

---

### What the port fixed along the way

Two things were wrong on macOS too and were repaired rather than
special-cased:

- **`NSAlert.runModal()`** in the notification and transmission settings
  blocked the main run loop — freezing the packet stream and every session
  timer behind a dialog asking for a callsign. Replaced by
  `TextEntryPrompt`, a SwiftUI alert that works on both platforms and blocks
  nothing.
- **Settings unreachable on iOS.** `SettingsRouter.openAction` is supplied by
  the macOS `Settings` scene, so on iPad every "Open Settings" button in the
  shared views did nothing at all. Worse, `GeneralSettingsView` — the only
  place `myCallsign` can be edited — was not reachable from anywhere in the
  iOS shell, so the transmit gate pointed at a screen that did not exist. The
  More tab now has a **General** row (first called Identity), and
  `openAction` pushes the screen matching `SettingsRouter.selectedTab` instead
  of merely switching tabs; switching tabs alone drops the operator on a menu
  and is visibly nothing at all if they are already on it. It adds to the More
  stack rather than replacing it (`SettingsDeepLink.path`, see Settings.md).
  With no callsign the transmit gate opens first-run setup, which works on iOS
  as a sheet, as does Add Radio.
- **Mail could be written but never sent.** The bigger absence behind the
  missing Compose button: iOS had no **Connect & Exchange**, so queued mail
  had no way off the device — the point of a Winlink client. The exchange
  needs the radio (`PacketEngine`), the session manager, the adaptive-session
  selector and the link-viz monitor, none of which `WinlinkMailboxScreen`
  received; they are threaded in now. The ladder walk is ported rather than
  shared, since the two shells differ in presentation — but the *rules* are
  the protocol's and match on both: refuse before keying when the callsign or
  password is missing, fall through to the next rung on a gateway-specific
  failure, and stop the ladder on a CMS-level one because it would repeat
  identically everywhere. `WinlinkExchangeFailureClass.isWorthTryingNextGateway`
  is shared and tested, so only the walk is duplicated — worth watching for
  drift.
- **A screen can be written and never referenced.** `WinlinkStationsScreen`
  existed in `AXTerm/iOS/`, complete with an empty state — and nothing linked
  to it, so the RMS gateway list was unreachable. The station map's own empty
  state told the operator to "refresh the station list on the Stations tab",
  a tab that did not exist on this platform. Both Stations and Contacts now
  hang off a Directory section in the mailbox sidebar, which is the split-view
  analog of the tabs the Mac puts beside Mail. Grep for unreferenced views
  when checking parity; a compiled file is not a reachable one.
- **Report Position and the Station Map are handheld features first.** Posting
  a position to the Winlink map is the self-spotting path when there is no
  cell coverage — the POTA/SOTA case, where the handheld is often the *only*
  radio present. The station map is distinct from the Map tab: that one plots
  stations *heard*, this one plots the gateways that can carry mail, with the
  link quality measured against each. Queueing a report is refused without a
  fix rather than sent with a guess, because an invented position will be
  believed.
- **Station tools followed.** Field Status, the ICS-309 communications log and
  the loopback test are on the same menu; the exchange console is a sheet.
  Its Done button dismisses the *view*, never the session — an exchange keeps
  running while the operator looks elsewhere, and stopping it is an explicit
  Abort, which the toolbar offers while one is in flight.
- **Composing was absent entirely.** The iOS mailbox toolbar carried only the
  sync indicator: no Compose, Forms or Catalog, and the Reply / Reply All /
  Forward buttons the detail view already drew were handed empty closures, so
  they rendered and did nothing. Compose is the awkward one — on macOS it
  opens a second window (`openWindow(id: "winlinkCompose")`), which the iOS
  shell has no equivalent for — so it is presented as a sheet. The draft is
  saved *before* the sheet opens, as on macOS, so a compose interrupted by a
  task switch is in Drafts rather than lost.
- **A `TextField` title vanishes on iOS when a prompt is set.** `To:` and
  `Cc:` are drawn beside the field on macOS and replaced by the placeholder on
  iOS, so compose arrived as unlabeled boxes. `LabeledContent` puts the names
  back on iOS without touching the Mac. The recipients field also lost its
  derivation tooltip to `.help()`; it is `.explain()` now.
- **`ByteCountFormatter` says "Zero KB".** Three words where a number belongs,
  next to a progress bar, wrapping the compose footer onto three lines.
  `compactSize` formats it, and distinguishes an empty draft ("0 KB") from one
  too small to round ("<1 KB") — those are different facts about a message.
- **The detail column never updated.** `WinlinkMailboxScreen` boxes its view
  model so `@StateObject` can own a model built from a store known only at
  init — but the box held the mailbox as a plain `let`, so SwiftUI observed a
  box that never changed. The message list kept working because it takes the
  mailbox as its own `@ObservedObject`; only the half with no observer of its
  own went stale, which is why the list responded to taps while the detail
  pane said "Select a message" forever. The box now forwards
  `objectWillChange`. Worth remembering: a partly-working screen is the
  signature of an observation gap, not of a data problem — the store round-trip
  was correct the whole time (`WinlinkSyncedMessageDisplayTests`).
- **A text field raises the keyboard over the list it was meant to reveal.**
  The destination picker anchored its suggestions to the callsign field. With
  the keyboard claiming the bottom half of an iPad, a popover was squeezed to
  about one row; moving it to a sheet was not enough either, because tapping
  the field still focused it and the sheet never opened — so the operator
  typed a callsign they could see listed but could not reach. On iOS the
  "To:" control is now a **button**, not a field: it opens a half-height sheet
  carrying its own search field *and* the list, both above the keyboard.
  Choosing a row selects and dismisses, because the choice is the whole
  answer; macOS keeps the inline field and popover.
- **Analytics and NET/ROM Routes were filed under Settings.** They are views
  of the network, not station configuration, and putting them there made that
  tab a drawer of leftovers. They now hang off **Packets**, with the traffic
  they are derived from; the tab is named *Settings* rather than *More* and
  carries only Station, Device and Diagnostics, each section with the
  explanatory footer iOS puts under a control rather than behind an ⓘ.
- **Saved station positions were never read back.** `StationsMapView`
  preloads positions from the persistent callsign cache in
  `.task(id: settings.callsignLookupEnabled)`, reading `stations` at the
  moment it fires. On iOS a tab's task runs when the tab appears — before the
  packet engine's initial load has produced any stations — so it preloaded an
  empty list, and because the id never changed it never ran again. The
  positions were on disk the whole time; nothing read them. Keyed on the
  sorted *set* of heard callsigns now, so it re-runs when the stations arrive
  and when a new one is heard, but not on every packet from a station already
  known.
- **An unordered diff compared as if it were ordered.** `updateMapView`
  checked `mapView.annotations` — which MapKit returns in no particular order
  — against the freshly built array, so it reported a difference on almost
  every pass and rebuilt every annotation for nothing. That is the flicker
  the operator saw. It became a *freeze* once the tap target was big enough
  to hit: the rebuild deselected the tapped annotation, MapKit reported that
  as a user deselection, the delegate wrote `selection = nil`, SwiftUI
  updated, and the rebuild ran again. Compared as sets now, with a
  `isRebuildingAnnotations` flag so a deselection caused by our own teardown
  is never mistaken for the operator's, and the delegate writes `selection`
  only when it actually changes. Two symptoms, one cause — and the flicker
  was the earlier, quieter half of it.
- **Dots need a tap target and a name.** The dot replacing the pin was 15pt,
  so the tap target was 15pt against Apple's 44 — most taps landed on the map
  and the marker looked functional while doing nothing. And
  `MKMarkerAnnotationView` had been drawing the callsign for free; a plain
  annotation view draws nothing, so the dots were anonymous. The view is now
  96×56 with the dot centered in it and the callsign beneath, and
  `collisionMode = .circle` keeps two nearby stations both tappable.
- **Overlays on a full-bleed map must restore the safe area.** The map ignores
  it deliberately so terrain runs to the edges, which left the legend sitting
  on the home indicator.
- **Stations were drawn as pins.** `MKMarkerAnnotationView` is a ~40pt balloon
  whose *tip* is the position; a few of them over a city read as pushpins in a
  paper map, covering the terrain being judged. `StationDotAnnotationView`
  draws a dot centered on the coordinate, reusing the legend's colors, with
  the scope's hollow-and-dashed convention for an inferred position and a
  larger dot for this station.
- **`Table` collapses to one column only in *compact* width.** The blank
  mailbox rows below were caused by this, but the rule is narrower than it
  first appeared: at regular width — a full-screen iPad — `Table` renders every
  column. `WinlinkMessageList` collapsed because it sits in the narrow content
  column of a `NavigationSplitView`; `NetRomRoutesView` and `DiagnosticsView`
  are full-width and were never collapsed. Check the width class before
  assuming a table is losing columns.
- **A Mac-sized toolbar forced the whole view off-screen.** `NetRomRoutesView`
  lays its controls out in one `HStack` with fixed widths (340 + 160 + 180,
  plus a toggle and four buttons) — fine in the 900pt window it was designed
  for. An `HStack` cannot shrink below its content, so on an 834pt iPad it
  forced the enclosing `VStack` wider than the screen and dragged the table's
  leftmost column, the callsign, off the left edge; the refresh, export, clear
  and rebuild buttons were unreachable off the right. It scrolls horizontally
  on iOS now.
- **Nine columns do not fit a handheld.** Even rendering correctly, the Routes
  and Link Quality tabs truncated the destination callsign to `KB5YZB…` while
  `Hops` kept a column to itself, and `df`/`dr`/`ETX` sat at 50pt each. Both
  get stacked rows on iOS via `NetRomTouchRow`. Neighbors keeps its table:
  five columns fit, and converting it would be churn. The tooltips moved to
  `.explain()` in the process — the columns used `.help()`, which renders
  nothing on iOS, so every derivation CLAUDE.md requires was already silently
  absent there.
- **`Table` shows only its first column on iOS.** `WinlinkMessageList` is a
  six-column `Table` whose first column is `TableColumn("")` — a 30pt
  indicator holding an unread dot and a paperclip. On iOS that is the *only*
  column rendered, so a read message with no attachment drew a row containing
  nothing at all. The mailbox looked empty while holding mail, which reads as
  sync being broken rather than as a layout bug, and sent the investigation
  after CloudKit for a long time. iOS now gets a `List` with a purpose-built
  row; macOS keeps the table. Other iOS-reachable tables (`NetRomRoutesView`,
  `DiagnosticsView`) are degraded rather than blank, because their first
  column carries real content.
- **Launch is not a scene-phase change.** The iOS shell drove both the sync
  trigger and (once added) auto-connect from `onChange(of: scenePhase)`, which
  never fires for the initial `.active` — the phase is already active by the
  time the observer attaches. So the app came up neither synced nor connected
  and stayed that way until the operator happened to switch away and back.
  macOS avoids this by pairing the observer with a `.task`; iOS now does the
  same.
- **Auto-connect was macOS-only.** `autoConnectOnLaunch` was honored in
  `AXTermApp` and nowhere else. On iOS it also has to mean *and after every
  suspension*, because iOS suspends the app and drops the socket to the TNC —
  a launch-only reconnect would work exactly once and look broken thereafter.
  Skipped while a link is already up or opening, since a second attempt tears
  down the socket the first is still establishing.
- **The link was invisible off the Terminal tab.** A packet station whose TNC
  has dropped looks exactly like a quiet channel: no error, no packets,
  nothing. macOS carries this in the toolbar permanently; iOS showed it on one
  tab. `TNCStatusStrip` now rides the TabView itself. It is graded rather than
  uniform — connected is a bare green dot with no text, connecting is muted
  and explains the pause, and only disconnected/failed take words, color and
  a link to Connection settings. It sits on the **bottom** edge because
  iPadOS floats the tab bar over the top of the content, so a top inset hides
  the tabs.
- **No way to connect at all.** Every `connectUsingSettings()` call site lived
  in `MenuBarView`, `AXTermApp`, or `ContentView` — all macOS-only — and
  `ConnectionSettingsView` showed status without offering an action. So an
  iPad could be configured with a host and port and then simply never open
  the link. Compounding it, that screen calls `suspendAutoReconnect(true)` in
  `onAppear` so edits do not tear the link down mid-keystroke, which means
  nothing would connect on its own while the operator sat there looking at
  it. `ConnectionSettingsView` now carries a Connect/Disconnect button that
  lifts the suspension before connecting; it is offered on both platforms
  because the host and port are edited right there.
- **macOS-only switches on a handheld.** `GeneralSettingsView` offered "Show
  icon in Menu Bar" and "Launch at Login" on iOS, where neither concept
  exists. A switch that cannot do anything reads as a broken setting rather
  than an absent one, so both are `#if os(macOS)`.
- **Silent save failures.** `PacketInspectorView` reported a failed JSON
  export with `NSSound.beep()`, which says something went wrong without
  saying what — and says nothing at all on a device with the ringer off. Now
  routed through `.exportFile` with a real message.

---

## 5. Project layout

One `PBXFileSystemSynchronizedRootGroup` (`AXTerm`) shared by both app
targets, with a per-target `PBXFileSystemSynchronizedBuildFileExceptionSet`.
Adding a file to the folder puts it in both targets automatically; excluding
it from iOS is one line in the exception set.

- Target `AXTerm-iOS`, bundle `com.rosswardrup.AXTerm`, deployment iOS 18.0,
  `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone and iPad)
- `AXTerm/AXTerm-iOS.entitlements` — CloudKit and the shared container
- `AXTerm/iOS/AXTerm-iOS-Info.plist` — the keys the generated Info.plist
  cannot express (`CFBundleDocumentTypes`, `UIFileSharingEnabled`). It is the
  target's `INFOPLIST_FILE`, merged with the generated keys, and is listed in
  both targets' exception sets so it is never copied in as a resource.
  `INFOPLIST_KEY_UIFileSharingEnabled` does nothing, which is why that key
  lives in the file.
- The macOS-only icon catalog (`Assets/Icon/Assets.xcassets`, `mac` idiom
  images) is excluded; the iOS target needs its own app icon

Two gotchas worth recording, both of which produce "The project is damaged":
Xcode object identifiers must be **exactly 24 characters**, and every
identifier must be unique.

---

## 6. Sync across all three

`Docs/UnifiedMailbox.md` covers the rules. `CloudKitSyncTransport` contains no
`#if os(...)` — the same file compiles for all three platforms, because
CloudKit has no platform-specific surface here.

The device-local policy matters *more* on a handheld, not less: a phone is the
device most likely to be somewhere other than where a link measurement was
taken, which is exactly why `stationPreferences`, `gatewayLadder`,
`sessionLog` and `gridSquare` never leave the device that recorded them.

---

## 7. Building

```bash
xcodebuild build -scheme AXTerm-iOS -destination 'generic/platform=iOS Simulator'
```

The macOS scheme, tests and behavior are unchanged. See `Docs/OfflineMaps.md`
for the stored basemap both platforms share.

## The iOS shell never wired the coordinator (fixed 2026-08-25)

The Mac's `ContentView.init` hands `SessionCoordinator` three things before
anything can transmit: the operator's callsign, the settings store, and the
`PacketEngine` to send through. `AXTermiOSRootView.init` constructed a
coordinator and handed it none of them, so on iOS the transmit path ran with
`localCallsign == "NOCALL"` and `packetEngine == nil`.

Field capture, connecting to W0ARP-10 from the iPad with the Mac shut down:

```
[KISS TRACE] TX AX.25 | dest=W0ARP-10 src=NOCALL type=u ctl=0x3F
[KISS TRACE] RX AX.25 decoded | src=W0ARP-10 dest=NOCALL type=U ctl=0x73
[──] [SESSION] Skipping sendFrame - packetEngine not set | destination=W0ARP-10
```

`0x73` is `UA | P/F` — the gateway **accepted** the connection. It then polled
with `RR P=1` (`0x11`) and finally gave up with `DISC P=1` (`0x53`). Nothing
was wrong with the path or the radio. Two independent faults hid that:

- **No packet subscription.** `subscribeToPackets(from:)` was never called, so
  `handleIncomingPacket` never ran and the UA never reached the state machine.
  The session sat in `connecting` through all N2 retries against a link that
  was already up on the far end.
- **No callsign.** The SABM went out under `NOCALL`, which is not a callsign
  the operator holds. Even had the UA been processed, the exchange was not
  identified.

The retries after the first were never transmitted at all — `sendFrame` returns
early when `packetEngine` is nil, and it logged that at `debug` with the
comment "e.g., in tests". That line is now a `warning`: outside tests it means
the state machine believes it transmitted when nothing reached the air, which
is precisely the fault that is undiagnosable from its symptoms.

`applyLocalCallsign(_:)` was added alongside, because the iOS root view
re-initializes freely and an unconditional assignment would both publish from
inside a view update and — since a callsign change purges sessions — silently
drop a live link on every re-init.

The lesson is the same one `WinlinkStationsScreen` taught: **parity audits that
compare views miss wiring that lives in an initializer.** The two shells are
written twice on purpose, and everything the Mac's `init` does to a shared
object has to be done by the iOS one too.

## Karn's algorithm was missing on the connect handshake (fixed 2026-08-25)

The I-frame path discarded ambiguous RTT samples correctly — `rttSendTime(ackedBy:)`
returns nil for a retransmitted N(S). The SABM→UA path did not: it measured
from `sabmSentAt`, which is set once at the first SABM and deliberately kept
(the late-UA window is measured from it), so the sample spanned every retry.

Field capture, W0ARP-10 on a busy channel — UA arrived on the 5th SABM after
4+8+16+30s of backoff:

```
[──] [RTT] Update | peer=W0ARP-10 rto=30000.0ms rttvar=30560.3ms srtt=61120.5ms
```

The path's real round trip was 1.8s, measured on the same link minutes earlier.
The session then ran with `rto=30.0s` (clamped to the maximum) and `t3Timeout=30.0`,
so every poll cycle waited half a minute on a healthy link.

The fix is a `sabmRetransmitted` flag on `AX25Session`, set when T1 fires while
`connecting`, cleared at each fresh connect, and checked before the sample is
taken. No sample is better than one built from the backoff ladder — the timers
keep their previous estimate.

Note this is separate from the *channel* being busy, which is why the SABMs
needed retrying in the first place. Congestion explains the retries; the missing
Karn guard explains why one congested connect poisoned the rest of the session.

## Mail UI on iPad (2026-08-25)

### Exchange console

`WinlinkExchangeConsoleView` carried `.frame(height: 190)` — the right size for
a Mac popdown sitting under a window that already shows the progress card. On
an iPad the same view is presented as a sheet, so 190pt of transcript sat at
the bottom of an otherwise empty screen.

- The height is now `.frame(maxHeight: .infinity)` on iOS and stays 190pt on macOS.
- A new `WinlinkExchangeStatusHeader` sits above the transcript on iOS only.
  The Mac has other places to read progress; the handheld sheet is the whole
  screen, so it has to answer "is it working?" before the B2F lines begin.
- Icon buttons get a 34pt hit target on iOS (they were glyph-sized).

`WinlinkExchangeStatus` holds the derivation so the wording is testable without
a view: phase → title, progress → fraction/bytes/rate/ETA, summary → the
completion line. Note `WinlinkExchangeStatus.make` takes `now`, because a rate
and an estimate cannot be tested against a wall clock.

The completion wording for an empty exchange is deliberate: "Nothing queued
either way — the mailbox is up to date." A bare "Exchange complete" after a
session that moved nothing reads as a failure to most operators.

### Message list

The row showed everything a message *has* rather than the few things a mail
client is read by. Three changes, all in `WinlinkMessageRowModel` so they are
testable:

- **Dates** follow the universal mail convention — time today, "Yesterday",
  "Aug 23" this year, "7/21/25" older. The old full stamp ("Aug 24, 2026 at
  10:52 AM") was wide enough to truncate the sender beside it.
- **`SMTP:` is stripped** from correspondent addresses. It records how a
  message traveled, not who sent it, and it pushed the readable half of an
  address off the end of a one-line row.
- **The delivery badge is suppressed** for `received` and `sent`. Every row of
  an Inbox is received; a badge that appears on all of them is furniture. It
  still shows for `draft`, `queued`, `sending` and `failed` — verified on the
  simulator: absent throughout the Inbox, present on the failed Outbox row.

Size stays on the row, because airtime is the scarce resource on a packet link
— it just moved to `.tertiary` so it stops competing with the subject.

The toolbar's `SyncStatusIndicator` now passes `showsLabel: false` on iOS. The
relative-time label is sized for a Mac toolbar; in a split-view column it
truncated to "ju..." and crowded out the compose and exchange buttons.

## Round two of iPad fixes (2026-08-25)

**Dashboard clipped off both edges.** `WinlinkExchangeDashboardView` carried
`.frame(minWidth: 860, …)` — a window measurement. In a sheet the system owns
the width, so a hard minimum overflowed instead of fitting, and the panels were
cut off left and right. The frame is now macOS-only, and the two side-by-side
panel pairs stack vertically on iOS via `adaptivePair`.

**Contacts never synced.** `WinlinkSyncPolicy` declared `.contact` syncable
from the start — "an address book is about people, not equipment" — and nothing
implemented it. The controller logged `4 sources: message, messageState,
callsignBase, operatorProfile` while the settings panel told the operator that
contacts sync. `WinlinkContactSyncSource` closes it, keyed on the contact's
*address* (callsign, else email, else name) rather than its rowid, which means
nothing on another device. `lastUsedAt` stays local — recency describes this
device's habits, like the gateway ladder.

**Unread badge stayed lit.** `WinlinkContext` keeps its own `unreadCount` for
the tab badge, because the badge outlives any one mailbox screen. Reading a
message updated only `WinlinkMailboxViewModel.unreadCount`; nothing bridged the
two, and on iOS opening a message never calls `refresh()`. The count now flows
through one `setUnreadCount` that fires `onUnreadCountChanged`, wired to
`context.refreshUnread()` on both platforms.

**Stations vanishing from the map.** `StationDotAnnotationView` set
`displayPriority = .defaultHigh`, which lets MapKit hide a marker whose
collision frame overlaps a neighbor's — and the frame is 96×56 so a finger can
hit it. Two stations a few hundred meters apart collided at city zoom and one
disappeared while the header still counted it as placed. Now `.required`.
Overlapping labels are a legibility problem the operator can solve by zooming;
a silently hidden station is not.

**Row tooltips removed.** The `.explain()` popover on each message row fired on
long-press, overlapped the list, and repeated what the row already said.

### Testing note

`@MainActor` XCTestCase methods that build a view model **must be `async`**.
A plain `throws` test lets the object deallocate off the main actor at scope
exit and the implicit deinit aborts — it surfaces as a 0.000s failure with no
assertion text, reported as `Crash: … __deallocating_deinit`. Tests whose
closures capture the view model accidentally pass, because the retain cycle
means it never deallocates. See [[axterm-mainactor-default-isolation]].

## Node profiles (2026-08-25)

A callsign shows up in a terminal line, a map pin, the Stations table, a via
path and a gateway ladder, and each place answered "who is this?" with the
fragment it happened to hold. `NodeProfile` assembles the fragments once.

- **`NodeProfile`** (`Station/NodeProfile.swift`) — a pure value built from
  snapshots. Alias resolution, license details, placement with confidence,
  activity, NET/ROM facts, Winlink history, and inferred roles.
- **`NodeProfileResolver`** (`UI/NodeProfileCoordinator.swift`) — gathers the
  scattered sources so the view never learns where any of it comes from.
- **`NodeProfileCoordinator`** — one door: `peek` for the sheet, `openPage`
  for the full page, `promoteSheetToPage` for the button between them.
- **`NodeProfileView`** — the same content in both presentations.

**Roles are evidence, not configuration.** Each role states what it was
inferred from, because every one of them is a guess made from observed
traffic: a digipeater is a callsign seen in someone else's via path, a NET/ROM
node is one in the neighbor table. A station with no evidence claims no roles.

**Alias taps keep their provenance.** Tapping `DRLNOD` opens `KE0NCQ-7`, and
the header says it was reached by tapping the alias — otherwise a tap silently
becomes a different callsign.

**Position confidence is carried through and explained.** A node placed at its
operator's license address is a lead, not a location, and the page says so.

### Deliberately not built yet

**Connect from a profile.** `ConnectCoordinator.requestConnect` needs a full
`ConnectRequest` — mode, intent, digipeater path — and guessing those is
guessing at what goes on the air. `NodeProfileView` already takes an
`onConnect`; iOS passes nil until the request can be constructed correctly.
See AXTERM-TRANSMISSION-SPEC.md.

**Map focus.** "Show on Map" switches to the Map tab but cannot yet center on
the station — there is no focus channel into `StationsMapView`.

**macOS entry points.** `ConsoleView` takes the handlers and macOS passes nil,
so the Mac console is unchanged. The profile view itself is cross-platform.

## Weather, station profiles, and three SwiftUI traps (2026-08-25)

### Forecast: one place, read vertically

`NWSTabularForecastView` rendered the product as it arrives — two dozen cities
across seven days — which forced a horizontal scroll where a row and its column
header could never be on screen together. It now opens on **one** place, chosen
by matching the station's own town (`StationProfile.city`) against the product's
city names, with a grouped picker for the rest and the full grid behind a
disclosure. Verified on the Mac against a live SFTCO product.

### Station profiles

`NodeProfile` gained `DirectedLink` and `Sibling`:

- **Both directions of a link, never blended.** Verified against W0ARP-10:
  68/255 outbound, 247/255 inbound — df 0.73/dr 0.37 out, df 0.98 in. One
  averaged number would read as a mediocre path and send the operator looking
  at the wrong end. ETX follows the spec formula and is clamped to [1, 20].
- **Siblings** group other SSIDs of the same license. `K0NTS-1/-7/-10` is one
  operator running three services.

Connect from a profile builds a real `ConnectRequest` with
`executeImmediately: false` — it prefills the terminal and never keys the
radio. Mode comes from `preferredMode`, and a previously heard digipeater path
is reused with a note saying so.

### Three SwiftUI traps, all found by driving the running app

1. **Two `.sheet` modifiers on one view: only the last works.** The peek sheet
   opened once and then silently stopped for the rest of the session, because a
   second `.sheet` for the full page was attached to the same view. Both now
   come from one `NodeProfileCoordinator.Presentation` enum.
2. **A blanket row gesture swallows its children.** `ConsoleLineGroupView`
   attached `.contentShape(Rectangle()).onTapGesture` unconditionally and
   checked `duplicateCount` *inside* the closure — too late, the gesture had
   already consumed the event. It is now installed only when there is something
   to expand.
3. **`.onTapGesture` beside `.onLongPressGesture` is unreliable** — the long
   press can consume the tap. iOS uses `simultaneousGesture`; macOS gets a
   right-click `contextMenu`, which is the idiom it actually has.

A macOS sheet also has no swipe-to-dismiss, so it needs an explicit Done button
— the first version was a trap with no way out.

## Link quality history (2026-08-25)

`link_stats` holds only the *current* estimate per link, so the app could say
what a path is like and never whether it had changed — a station that degraded
over an afternoon looked identical to one that was never good.

- **Migration v12** adds `link_quality_history`: append-only, indexed by link
  and by time.
- **`SQLiteLinkQualityHistoryStore`** samples on the NET/ROM snapshot save,
  which already runs about once a minute with the stats in hand — no new timer.
  Rate-limited to one sample per link per 30 minutes (checked *per link*, so a
  newly heard station is recorded at once), pruned at 14 days.
- **`LinkQualitySparkline`** draws it in the profile: spaced by *time* rather
  than by index, so a gap where the station went unheard stays visible, and
  scaled against the full 0–255 range so a flat link looks flat.
- **`NodeProfile.trend`** compares the mean of the oldest third against the
  newest third — steadier than first-versus-last on a jittery metric — and
  returns nil below six samples rather than calling two readings a direction.

Confirmed writing real samples on the Mac, e.g. `W0ARP-10 → K0EPI-7 · 247 ·
df 0.979`.

`DiagnosticsView` also got its iOS touch list — the last of the `Table`-only-
renders-its-first-column screens. It had shown a column of bare timestamps with
no level, category or message, on the one screen that has to be readable when
something has gone wrong.

### Directory lookup was never triggered from a profile

`NodeProfileResolver` read `CallsignLookupService.records` — the *cache* — and
nothing ever called `resolve()`. The cache was only ever filled by
`StationsMapView`'s preload, so a callsign the operator had not already seen on
the map showed "Nothing known yet" even with lookup switched on.

Both shells now `.task(id:)` a lookup when a profile opens, and the empty state
tells the truth in three different situations: looking up, looked up and found
nothing, or lookup switched off. It used to advise enabling a setting that was
already enabled.

Verified on the Mac: K0NTS-1 resolves to "Colorado Traffic League · Evergreen"
from HamDB, with K0NTS-7/-10/-14 listed as siblings and their roles.

### A verification trap worth recording

The terminal auto-scrolls. A click aimed from a screenshot lands on a
different line by the time it fires, which looks exactly like a dead gesture —
it sent me rewriting two pieces of working gesture code. Turn auto-scroll off
before driving the console.

## NET/ROM is a declaration, not an inference (2026-08-25)

`NodeProfile` labeled any station in the NET/ROM neighbor table a "NET/ROM
node". That table is built by watching traffic — `NetRomRouter.observePacket`
records **any** direct frame — and its "classic" versus "inferred" labels
distinguish two *inference paths*, not declared versus guessed. `isOfficial`
exists on `NeighborInfo` but is never set true anywhere. So the label landed on
ordinary stations that merely transmitted nearby.

Only two things are the station's own word, and `NetRomDeclaration` now
requires one of them:

- **`.nodesBroadcast`** — it originated a NET/ROM routing broadcast (PID 0xCF
  to NODES). Nothing but a node sends one. Detected from routes carrying
  `sourceType == "broadcast"`.
- **`.aliasAnnouncement(alias)`** — its ID or beacon announced a node alias,
  e.g. `KE0NCQ/R DRL/D DRLBBS/B DRLNOD/N`.

The neighbor quality is still shown, because it is a real measurement — the
section now says explicitly that appearing there means "nearby and audible",
not "runs NET/ROM".

## Utility callsigns

`BEACON`, `ID`, `NODES`, `QST`, `MAIL`, `WIDE1-1` and the rest are destinations
frames are sent *to*. `CallsignValidator` already knew them; it now exposes
`isServiceEndpoint(_:)` so the UI can act on it. Their profile says "Not a
station", explains what that particular destination is conventionally for, and
offers **no Connect button** — there is nothing there to answer one.

Crucially it does not say "nothing known yet", which invited the operator to
wait for a lookup that will never return anything. There is nothing to know.

## Notes and photos (migration v13)

`station_notes` and `station_attachments`, keyed by callsign *including SSID* —
a note about `K0NTS-10` the mailbox is not a note about `K0NTS-1` the node.
Attachment bytes live in their own table so drawing a list of names does not
read every image off disk. Capped at 8 MB with the actual size reported back
when something is refused.

Device-local for now. Notes are about people, so the same argument that makes
`.contact` syncable applies — but photos are heavy for CloudKit and that
deserves its own decision.

## Local and downloaded gateway sets (migration v14)

`gateway/status.json` has **no geographic filter**. It returns every public
gateway in the world on every refresh, and `maxDistanceMiles` is applied on
this device afterwards. The wide list was already being downloaded and then
discarded — so "download a region for a trip" was never a network problem, only
a retention one.

`WinlinkRMSStationRecord.Scope` splits the cache in two:

- **`.local`** — "who can I reach from here". Refreshed often, bounded by the
  radius, small enough to scan.
- **`.global`** — "who exists along the route". Fetched deliberately before a
  trip, and *not* destroyed by an ordinary refresh at home.

That last point was the actual bug: `replaceStationCache` deleted every row, so
a 100-mile refresh would wipe a list fetched for a journey — the one thing that
list exists to survive. It now replaces one scope at a time, and a gateway that
falls in both keeps its **local** row, because that row's distance is measured
from where the operator actually is.

### Regions are Maidenhead fields, not states

`WinlinkRMSStationRecord` carries a grid square and no other geography. Offering
to download "Colorado" would mean inventing a boundary the data cannot support
and then getting it wrong at the edges. A two-character field (`DM`, `DN`) is
roughly 10° by 20° — coarse, but honest, and it is what a traveling operator
reasons in anyway.

The sheet lists the fields that actually have gateways, with counts, and marks
the operator's own. It also says plainly that this has to be done while a path
to the internet still exists, because there is no way to fetch it from the field.

## Intuiting the local network without NODES broadcasts

Most networks — including the Denver one — never broadcast NET/ROM `NODES`, so
the routing-broadcast path finds nothing. But nodes, BBSs and digipeaters
identify themselves anyway: the ID frame is a license requirement and operators
fill it with a service list. That list *is* the directory the network publishes
about itself, arriving over the air with no internet and no registry.

Real frames from the local network:

```
KB5YZB-7 → ID      KB5YZB/R YZBBPQ/D KB5YZB-1/B KB5YZB-7/N
KE0NCQ   → ID      KE0NCQ/R DRL/D DRLBBS/B DRLNOD/N
KD0SSP   → BEACON  … Digipeat Alias = DWARC; Node:KD0SSP-7; PBBS:KD0SSP-1
```

`NodeAliasParser` already read these frames — but only to resolve tactical
aliases, so `parseServiceList` deliberately skips any token whose name is a
callsign. That discarded the two most direct declarations in the frame:
`KB5YZB-1/B` ("this callsign runs a BBS") and `KB5YZB-7/N` ("this one is a
node").

`StationServiceParser` reads both forms plus the prose one, because operators
write beacons for humans and a directory built only from the slash form would
miss stations announcing loudly in words. Declarations feed `NodeProfile.Role`,
so a station's page now says it runs a BBS *because it said so*, quoting the
frame.

### What it deliberately does not do

`Colorado Traffic Net BBS & RMS.  Connect to K0NTS-1 & K0NTS-10` names two
callsigns without saying what they are. Inferring "BBS" from an invitation
would be a guess dressed as a declaration, and there is a test pinning that it
yields nothing.

Repetition is recorded (`timesHeard`): an ID heard once could be a decode
error, the same claim every ten minutes for a week is the network describing
itself reliably.

## The network directory persists (migration v15)

`station_services` keeps what each station runs, at two confidences:

- **declared** — it announced the service in an ID or beacon.
- **demonstrated** — its callsign appeared in a via path with the
  has-been-repeated bit set, so it did the job while we listened.

The distinction matters because they are earned differently. A station can
claim to digipeat and be misconfigured; it cannot fake having repeated a frame
that reached us. Only digipeating is provable this way — nothing a BBS or node
does shows up in a frame header.

`timesHeard` accumulates rather than being overwritten: an ID heard once could
be a decode error, the same claim every ten minutes for a week is the network
describing itself reliably, and only a running count separates them.

Verified against live traffic — 25 seconds of listening produced:

```
declared      KD0SSP-1/B ×16   KD0SSP-7/N ×16
              KB5YZB-1/B ×11   KB5YZB-7/N ×11   KB5YZB-7/D (YZBBPQ) ×11
              KE0NCQ/N (DRLNOD) ×10  KE0NCQ/B (DRLBBS) ×10
              AB0VZ-7/N ×2     AB0VZ-3/G ×2     N0BN-7/N ×1
demonstrated  DRLNOD/D ×16     HORSE/D ×2       AB0VZ-7/D ×1
```

### Two bugs the tests caught

**Alias digipeaters were being rejected.** The harvester required
`isValidCallsign`, so `DRLNOD` and `HORSE` — the nodes this network actually
runs on — were discarded. A digipeater is as often a tactical alias as a
callsign. The filter now accepts either and excludes routing *conventions*
instead: `WIDE1-1` is an instruction, not a station, and rides on every frame.

**macOS harvested only on the Map tab.** The call sat inside the navigation
switch, so the directory grew only while someone was looking at a map — the one
time they are not reading it. Both platforms now harvest from the packet stream
wherever the operator is.

## Path heuristics and the network on the map

`NetworkPathObserver` derives topology from overheard traffic. Distinct from
`NetRomRouter`, which answers "how would *we* reach this destination" — this
answers "what paths exist on this channel at all", including between two other
stations we merely overhear. Where a network sends no NET/ROM broadcasts, that
overhearing is the only source of topology there is.

Four evidence levels, ordered weakest to strongest, and the ordering is the
point — presenting a guess beside a proven path would turn it into a
recommendation:

| Evidence | What was observed |
|---|---|
| **Inferred** | Both ends reach the same digipeater. Never actually tried. |
| **Heard direct** | A frame was overheard passing directly between them. |
| **Digipeated** | A frame arrived through this path, so every hop repeated it. |
| **Session completed** | A connect request was *answered*. Frames crossed in both directions. |

A `DM` counts as an answer: "reachable, not listening" means the session failed
but the path demonstrably did not.

**Negative evidence is kept too.** Unanswered connect attempts accumulate, and
a path with two or more that never completed is marked suspect and drawn red —
a plausible-looking path that never answers is the one that wastes the most
airtime. This is exactly the `K0NTS-1 → KF0BPN-1` case in the local traffic:
called every six seconds, never answered.

### On the map

Great-circle polylines between placed stations, colored by evidence and dashed
where nothing has actually traveled the path. Below the labels, because the
network is context for the stations and a web of lines over the place names
would bury what they connect. Off by default — an operator opening the map
usually wants to know where stations are before how they connect.

Paths with an unplaced end are dropped rather than guessed at, and two SSIDs
sharing one coordinate draw nothing: a license-address link would be a dot.

### Two bugs the tests caught

- **UA was checked as `0x6F`; it is `0x63`.** Every handshake was being missed,
  so no path ever reached the strongest evidence level.
- **Repeated connect attempts overwrote each other.** A node called every six
  seconds and never answered scored the same as one polite retry. They
  accumulate now.

## Network inference: topology and terrain

Three graph/RF features landed together — see `Docs/NetworkInference.md` for
the full treatment.

- `NetworkTopology` — iterative Tarjan articulation points and label
  propagation clusters over the observed path graph. Surfaced on the identity
  page as "In the Network", worded as consequences ("4 stations reach the
  network only through this one") rather than as graph theory.
- `PredictedPath` — terrain forecasts for pairs never heard talking, drawn on
  the map as purple dotted lines, off by default and disabled entirely when no
  elevation tiles are stored.
- `ElevationStorage` — the observable wrapper over `ElevationStore`, with a
  Terrain section in the Offline Data sheet (renamed from "Offline Map",
  since it now holds both). USGS 3DEP, no account required.

`NetworkInsightModel` fingerprints its inputs and computes off the main actor;
the map redraws on every packet and must not restart a terrain pass each time.

Physics note worth keeping: two 10 m antennas 13 km apart at 145 MHz clear
only ~9% of the first Fresnel zone. Sixty percent clearance over that distance
needs about 49 m of height. `PredictedPathTests` pins both the hilltop case
and the flat-ground case, because the flat-ground result reads like a bug and
is not one.

### Antenna height, and the download that ate a continent

Heights are now collected (meters stored, feet entered by default): own
station and an assumed-remote default in settings, a real per-station height
on each identity page (`station_notes.antennaHeightMetres`, migration v16).
Gain and antenna type are deliberately not collected — they do not enter
Fresnel geometry, and AXTerm computes no link budget.

Two bugs found by running the app rather than the tests:

1. `ElevationStorage.download(covering:)` was handed a bounding box of every
   placed station. One distant station made that a continent, and it fetched
   34 tiles / 143 MB from USGS before anything noticed. Now bounded to ~1.1°
   around the operator's own position, with an estimate and a confirmation
   above six tiles.
2. The sheet read `downloader.state` while observing only `ElevationStorage`,
   so the progress bar never moved. State is republished through the observed
   object.

Also: on the real Denver station set every untried path is genuinely blocked,
which drew an empty map. The paths menu now always reports the outcome and
names the nearest miss.

## iPad and iPhone polish (2026-09-30)

Found by driving the app on an iPad mini and an iPhone 17 Pro simulator
against a receive-only Direwolf with live APRS traffic.

### Packets

- **Tags.** A UI frame's tag comes from `PacketTypeTag`: the APRS data type
  when `APRSDigest` decodes it (POS, MIC-E, WX, OBJ, ITEM, STATUS, MSG,
  MSG ACK, MSG REJ, BLN, QUERY, TLM), otherwise ID, MAIL or BCN, the words
  the terminal's filter chips use. Telemetry setup messages (`PARM.`,
  `UNIT.`, `EQNS.`, `BITS.`) are TLM, not MSG. Connected-mode frames keep
  their control-field tag. Routing still reads `PacketClassification`; the
  tag is display only. The Mac table and the inspector header use it too.
- **Copies.** `PacketDuplicates` marks the same frame heard again by another
  path within five seconds, the terminal's rule and window. The first
  sighting shows the terminal's "+1"; each later one shows "copy" and dims
  its payload. iOS only for now.
- **Tap to open.** A tap opens the inspector sheet; the long-press menu is
  still there. The sheet has Done and no Close button.

### Terminal

The filter chips keep their labels on one line and scroll sideways when the
row is short. The session line says "No session", with "Pick a station to
connect to" when the TNC is up, so it cannot be read as the TNC being down.
On an iPad the compose bar takes the phone's two-line layout when one line
does not fit (`ViewThatFits`), so the callsign field keeps its width and
"Auto Connect" stays on one line.

### Map

With no position of its own the map now draws the heard stations, centered
on them (`MapCenterRule`), with no pin of our own and no distances, under a
banner whose Set Position button opens General › Station position. The
scope view still needs a position. The legend starts closed on iOS. The
station card no longer repeats the callsign, quotes speed and course
("37 mph at 274°") when the beacon carried them, and says "Beaconed
position, heard over the air."

### Shell and settings

- The iPad's floating tab bar leaves wide margins, and seven names did not
  fit an iPad mini in portrait, so Messages and Settings hid behind a
  scroll arrow. Below 1,000 points of width the tabs show their symbols
  only (names stay as accessibility labels). Forcing a compact size class
  for the bottom bar was tried and rejected: UIKit then folds tabs five and
  up into More.
- Setup sheets (first run, Add Radio) size to their content: a height
  detent on a phone, a form sheet fitted to the content on an iPad.
- Coordinate fields use the numbers-and-punctuation keyboard, which has the
  minus sign a number pad lacks.
- The settings list shows the callsign under General and the radio's name
  and endpoint under Radios.

## Files in and out (2026-09-30)

### Winlink compose on a phone

The compose view is the Mac's, but its footer (Attach, Position, the size
gauge, Save Draft, Queue for Sending) wrapped every label on a 393-point
iPhone and on an iPad sheet. On iOS the 560 × 440 minimum frame is gone,
Queue is the navigation bar's confirmation action with Save Draft beside it,
and the bottom toolbar carries Attach and Insert Position as icons (with
accessibility labels) and a compact gauge. Help text says "Touch and hold"
where the Mac's says "Right-click". The view model is a `@StateObject`; built
in `init` as an `@ObservedObject`, each parent redraw made a fresh model and
dropped unsaved typing.

Attach is a menu: Files, Photos (`PhotosPicker`, several at once), Take Photo
(`ComposeCameraPicker`, only where `UIImagePickerController` reports a
camera), Paste, and Keep Photo Location. Drag and drop works on the whole
window. A photo too big for the message is shrunk by `ImageShrinker`; see
Docs/Winlink.md, "Photos".

### Received attachments

A tap previews with Quick Look. The menu adds Share (`ShareLink`) and Save on
iOS; the Mac gets Open and Show in Finder instead of Share. HEIC previews
inline.

### Getting files into the app

- `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` put the
  app's Documents folder in the Files app under On My iPhone › AXTerm.
  Nothing else lives in Documents (the database and caches are in
  Application Support), so what shows there is received packet files in
  `Documents/AXTerm Transfers`.
- `CFBundleDocumentTypes` claims `public.item` and `public.data` at rank
  Alternate, so "Open in AXTerm" and the share sheet's AXTerm entry appear for
  any file, without AXTerm becoming the default app for anything.
- The root view takes the file in `.onOpenURL`. `IncomingDocumentRouter`
  copies it into `tmp/Incoming Files/<uuid>/` inside the security scope and
  removes the copy iOS may have left in `Documents/Inbox` (the Files app
  would show it). `IncomingFileSheet` then offers "Attach to a new Winlink
  message" and, per connected packet session, "Send to <callsign> over
  packet". Winlink opens compose in the mailbox through
  `WinlinkComposeRequest` with the file attached as if picked, and saves the
  draft at once. Packet calls `SessionCoordinator.startTransfer` on the
  session's path with the peer's first available protocol and switches to
  the Terminal; that copy is purged a day later rather than deleted while a
  transfer may read it.

A share extension was considered and not built. It needs its own target and
signing, an app group to pass the file to the app, and a way to bring the app
forward, and "Open in AXTerm" already covers files from other apps. The
Photos app's share sheet only lists extensions, so photos are attached from
inside compose.

### Map layers

The iOS map now gets `onSendLayer`, so Send by Winlink appears in the layer
menu. It builds the Mac's draft (see `ContentView.sendLayerViaWinlink`) and
opens compose on it.
