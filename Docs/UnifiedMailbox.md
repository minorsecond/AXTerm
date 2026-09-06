# Unified Mailbox

Sharing one Winlink mailbox between an operator's devices — the home rig and
a handheld — so mail received on either is visible on both.

Status: **rules, engine and CloudKit transport implemented and tested.**
Mac-to-Mac needs only the CloudKit container provisioned (§9). iPhone and iPad
need an app target that does not exist yet; the sync layer already compiles
for them.

---

## 1. What is easy, and what is dangerous

A unified mailbox splits into two halves, and the split is not where people
expect it.

**The easy half is the mail.** B2F assigns every message a globally unique
MID, and this app treats delivered mail as immutable (CLAUDE.md §7). Merging
two mailboxes' *messages* is therefore a union keyed by MID with no field-level
conflicts to resolve at all.

**The dangerous half is everything that describes a particular radio at a
particular place.** Copying that to another device is not merging two views of
one thing — it is asserting something false about a second thing. A home rig's
digipeater path, its gateway ladder, and its measured link quality are all
statements about one antenna at one location. On a handheld they are wrong,
and wrong in a way the operator cannot see: the app would display a confident
quality figure for a link the handheld has never made.

`WinlinkLinkQuality.appliesHere` already refuses to treat a measurement taken
elsewhere as a prediction. Syncing session logs would smuggle in exactly the
thing that rule exists to prevent.

---

## 2. The policy

`WinlinkSyncPolicy.disposition(for:)` classifies every kind of state the
Winlink subsystem persists. Each carries its reason in the source, and
`WinlinkSyncPolicyTests` asserts that no kind is left unclassified.

| Kind | Disposition | Why |
|---|---|---|
| `message` | synced | Immutable, globally unique MID — union, no conflicts. |
| `messageState` | synced | Read flags and folders are the point of a unified mailbox. Merged by rule (§3). |
| `contact` | synced | An address book is about people, not equipment. |
| `catalogFavorite` | synced | An operator preference; travels with the operator. |
| `callsignDirectory` | synced | A licence address is the same fact everywhere. A device with no network benefits most from another's lookups. |
| `nodeAlias` | synced | `DRLNOD` is `KE0NCQ` regardless of which radio heard the beacon. |
| `stationActivity` | **attributed** | What another station heard is evidence worth reading, measured by a different antenna. Shown as that station's observations under "Other Stations"; never merged into routing metrics. |
| `terminalSession` | **attributed** | A finished terminal transcript is what was *said* over the air, not a measurement of it — so it may travel where `sessionLog` may not. It arrives in its own table (`remote_terminal_sessions`), is listed in the Terminal's History only behind the "Other devices" switch, in a section per device, with "From K0EPI-7 on Ross's Mac" on every row, and cannot be tagged or annotated. Only sessions ended in the last week are published; transcripts are cut at 200 KB and say so. Tags and notes never travel. |
| `partialInboundBody` | **session-local** | An `FS !offset` resume belongs to the one in-flight stream that started it. |
| `stationPreferences` | **device-local** | Digipeater paths are a property of *this* antenna. |
| `gatewayLadder` | **device-local** | An ordered list of gateways *this* radio can hear. |
| `sessionLog` | **device-local** | Link quality is measured from one place with one antenna. |
| `gridSquare` | **device-local** | A handheld's position is not the home rig's. |

---

## 3. Merging message state

`WinlinkStateMerge.merge(_:_:at:)`. Deliberately **not** last-writer-wins —
several fields are monotonic, and last-writer would destroy information.

- **`isRead`** — monotonic, true wins. Reading is a fact a stale replica
  cannot un-make. A device offline since before the message was read still
  holds `false`, and its later write must not resurrect the unread badge.
- **`folderId`** — last writer by `updatedAt`. Filing is a preference with no
  natural ordering, so the most recent decision stands.
- **`deliveryState`** — ranked, with two overrides. `sent` is terminal and
  beats everything: a gateway accepted the message, and no other device can
  undo that. `failed` beats the in-progress states it interrupted, because it
  is later information about a message that still has not arrived.
- **`lastError`** — kept only while it is the current story (newer side first).
- **`sentOffset`** — see §5. Follows the claim holder, never the larger number.

The merge is **symmetric** (both devices compute the same result) and
**idempotent** (re-merging a merged result changes nothing). Both are tested;
without them two devices ping-pong across a sync that never settles.

Absence is never deletion. A MID present on only one side is carried across:
this mailbox has no delete tombstones, and reading absence as a delete would
destroy mail whenever a device synced before it finished pulling.

---

## 4. The transmission claim

The one part of a shared mailbox that can cause harm on the air.

Two devices holding the same queued outbound message will **both** try to send
it. The CMS receives the same MID twice: duplicate traffic on a shared
channel, and airtime spent twice on one message. A shared mailbox therefore
needs an *owner* per outbound item, not just a merge rule.

`WinlinkTransmitClaim` is device ID + `claimedAt` + `expiresAt`.

- **Unclaimed or lapsed mail may be sent by anyone.** Failing closed would be
  worse than duplication: mail that silently never leaves is the failure an
  operator cannot see.
- **Claims expire** — default 45 minutes. A device that loses power mid-session
  must not strand the message forever. The window must outlast a real
  exchange; this station's own session log showed a ~19-minute cap on
  145.050, and a shorter window would lapse mid-send and invite the exact
  double transmission the claim prevents.
- **Conflicts resolve deterministically.** A lapsed claim never beats a live
  one. Between two live claims the earlier wins — the device that started
  first is the one likely to be mid-session — and an exact tie breaks by
  device identifier, so both sides reach the same answer without another
  round trip. Otherwise each device concludes it owns the send.

---

## 5. Resume offsets: the subtle one

`sentOffset` is a compressed-stream position agreed between **one radio and
one gateway**. The number is meaningless without knowing whose stream it
counts, so `offsetDevice` travels with it.

Merging by `max` looks obviously right and is a silent disaster. Two devices
part-way through sending the same MID to different gateways; taking the larger
offset makes the loser resume past bytes its gateway never received, and the
message arrives **truncated with no error raised anywhere**.

So the offset follows the merged claim holder. With no live claim there is no
stream to resume into, and the offset resets to zero rather than being
inherited by whoever picks the message up next.

---

## 6. Transport

`WinlinkSyncTransport` is a four-method protocol: device ID, availability,
fetch-since-token, push. Every rule lives above it in `WinlinkSyncEngine`, so
the whole design is tested by pointing two engines at one
`WinlinkInMemorySyncTransport` — which behaves exactly like a Mac and an
iPhone sharing an account.

### CloudKit

`CloudKitSyncTransport` uses the operator's **private** database. Winlink
traffic includes welfare and health-and-safety messages in an emergency; it
goes in the container only they can read, never a public or shared one.

One custom zone (`WinlinkMailbox`) so fetches are incremental — the default
zone has no change tokens, which would mean re-reading every message on every
pass. Payloads over 700 KB move as `CKAsset`, since CloudKit caps a record at
1 MB and a photo attachment from an ICS form clears that easily. Pushes batch
at 300 records, under CloudKit's 400-per-operation limit, so a first sync of a
full mailbox is not rejected outright.

An expired change token is reported as `wasReset` and re-read from the
beginning, never swallowed: a caller that believed its increment was complete
would silently miss everything in between.

The same file compiles unchanged on macOS, iOS and iPadOS — it contains no
`#if os(...)`.

### Never sync the SQLite file

Not via iCloud Drive, iCloud Documents, or any file-level sync. Those
replicate whole files with last-writer-wins and no awareness of WAL
journalling; two devices writing one database produce a corrupted store, not a
merged mailbox. Everything in §3 exists so merging happens per record.

---

## 7. Wire format

Two record kinds, because content and state behave differently.

- **`message`** — `WinlinkB2Message.encode()`, the protocol's own canonical
  bytes, plus direction. Written once and never revised. Reusing the B2F
  encoding rather than inventing a second format means there is no parallel
  serialization to keep in step with the protocol.
- **`messageState`** — small JSON. Changes every time somebody opens a
  message, so a read flag costs a few hundred bytes instead of re-uploading
  every attachment.

### Folders cross by identity, not by rowid

`folderId` is a local SQLite rowid and means nothing on another device: this
Mac's Archive may be row 5 while the iPhone's is row 6, and user folders exist
on one device and not the other. The wire carries `WinlinkSyncFolderRef` — the
folder's role if the system owns it, otherwise its name — and the receiver
resolves it locally, creating a user folder that only existed on the other
device. `testFoldersCrossByIdentityNotByRowID` numbers its two fake stores
differently on purpose so a regression here fails loudly.

### Every pass says what it did

A sync that reports nothing is indistinguishable from one that never ran, and
"is the other device pushing?" is the question that actually gets asked. So
each pass logs its outcome — including the early exits, which used to return
silently: sync switched off, no iCloud account, no syncable store, a pass
already running, and the finished report's counts.

It goes to the console as `[WINLINK:SYNC]` as well as to telemetry, because
telemetry is not running everywhere. Sentry was never started on iOS at all,
so the handheld — the device most likely to be missing mail — was the one that
could not be diagnosed. Both are fixed: iOS starts Sentry, and the console
carries the same lines regardless.

### A pass pushes only what changed

The engine keeps a **push ledger** (`recordName -> modifiedAt`) beside the
server change token. The token records what this device has *read*; the ledger
records what it has *written*, and a device needs both.

Without it a pass re-uploaded the entire mailbox every time. CloudKit then
reported all of it as changed, so the next pass pulled it all back and pushed
it all again: a loop that never settles, costing writes in proportion to
mailbox size rather than to activity. A live Mac was observed doing this at
`pulled=26 pushed=26`, twice, eight seconds apart.

An edited record still goes up — a read flag or delivery state moves
`modifiedAt`, and suppressing that would be worse than the loop, because the
other device would never learn. Records this device no longer holds leave the
ledger, so it cannot grow without bound, and it persists across relaunch so
restarting the app does not re-upload everything.

### The operator crosses; the station does not

`callsignBase` and `operatorProfile` carry the operator's licence callsign and
their name, organisation, phone and address — the ICS fields that are the same
on every radio they own, so a second device is usable without retyping any of
it. `WinlinkIdentitySyncSource` implements both.

What deliberately does **not** cross is the **SSID**. `K0EPI` is the operator;
`K0EPI-9` is a station. If the SSID travelled, two devices would answer to one
address — the collision `StationIdentityMonitor` detects and
`StationIdentityLease` prevents. So the SSID is stripped when publishing
(`narrowed(to: .callsignBase)`), discarded if one arrives anyway (`merge`), and
preserved on apply: `LiveIdentityStore` keeps this device's SSID and swaps only
the licence half, so an iPad running as `K0EPI-9` that adopts the Mac's callsign
stays `-9`. The grid square is excluded for the same class of reason — a
handheld is not where the home rig is.

Two rules protect against a fresh device wiping a configured one:

- An unconfigured device **publishes nothing** (`hasContent(for:)`), so its
  empty record never races a real one.
- A non-empty value is **never replaced by an empty one**, because a device
  mid-edit can briefly hold a blank field.

Otherwise it is last-writer-wins on the whole record rather than field by
field: these are one coherent identity, and this device's street beside the
other device's city would be worse than either.

### Sources are `async` because settings live on the main actor

`WinlinkSyncSource.localRecords()` and `apply(_:)` are `async`. The engine is
an `actor` and runs off the main thread on purpose — a pass does database and
network work — while `AppSettingsStore` and `StationProfile` are `@MainActor`
observable objects driving the UI. Reaching across that boundary with
`MainActor.assumeIsolated` **traps at runtime**; it compiles and then crashes
on the first pass. Making the requirement `async` moves the hop into the type
system. Sources whose state has no isolation simply never suspend.

### Drafts do not sync

A draft is still being typed. Syncing one lets two devices overwrite each
other mid-sentence, and the immutability the rest of this design leans on does
not hold until the message is queued.

### Provisional state

Content can arrive before its companion state record. Sync seeds a state so
the message is readable meanwhile, stamped `provisionalTimestamp`
(`Date.distantPast`) — the merge treats a provisional side as *no opinion* and
yields to the real decision wholesale. Without this the seed's guesses win:
mail files into the Inbox because the seed said Inbox, and a queued message
pins at `sent` because `sent` outranks everything by design.

The outbound seed is `sent`, not `queued`, deliberately. If the state record
never arrives, a wrongly-queued message is transmitted a second time and
nobody sees it; a wrongly-sent one sits in Sent where the operator can spot it
and resend. Failing toward silence on the air is the right way round.

---

## 8. Failure behaviour

- **No account** — reported as `skippedNoAccount`, not thrown. An operator in
  the field with no signal should find the app working alone, not an alert
  about iCloud. Sync is a convenience; the radio is the point.
- **One unreadable payload** — counted, and the batch retried record by
  record. A single corrupt or newer-format record must not cost the operator
  the rest of the mailbox.
- **Policy violation** — the engine checks `WinlinkSyncPolicy` itself rather
  than trusting its sources, and counts refusals. A future source that tried
  to replicate session logs or a digipeater path is stopped by the same check
  that documents why it must not.
- **Token advance** — only after everything applies. A token saved before a
  failed apply would skip those records forever.
- **Pull before push** — a device that pushed first would broadcast a state
  formed without seeing the other device's changes.

Every pass returns a `Report` (pulled / applied / pushed / refused /
unreadable / reset). When a message fails to appear on the other device the
question is always whether it was pushed, pulled, or refused, and this answers
it.

---

## 8a. Sharing one TNC between two devices

Two AXTerms pointed at one Direwolf is a normal arrangement — a desktop and a
laptop on the same LAN, or a Mac and an iPad reaching the same TNC over the
network. Direwolf accepts both KISS clients and serialises their
transmissions, so the *radio* is fine. Three things are not automatic:

**Same callsign-SSID breaks AX.25.** Connected mode keeps per-link state —
V(S)/V(R), a retry timer, a window — and assumes exactly one station answers
to an address. With two, both answer a SABM (the far end gets two UAs and
resets), both acknowledge I-frames, and a session one device opened is torn
down by the other's DISC. None of it produces a clean error; it produces
sessions that drop for no visible reason.

`StationIdentityMonitor` watches for the signature — a frame whose source is
this station's own address that this station did not send — and raises a
banner naming the cause and the fix. It fingerprints transmissions on
(source, destination, control, info) rather than raw bytes, because a
digipeater rewrites the has-been-repeated bit and byte comparison would fire
a false alarm on every frame through DRLNOD. See `Docs/SharedTNC.md`.

**Queued outbound mail is covered — but only with sync on.** The transmit
claim in §4 is what stops both devices sending the same MID. It works through
CloudKit, so two devices sharing a TNC with sync *off* have no protection and
will both transmit.

**P2P listening should be armed on one device only.** An armed station answers
inbound Winlink calls and transmits in reply with no operator present; two
armed stations on the same callsign answer the same call.

---

## 9. Platform status

| Platform | Status |
|---|---|
| macOS ↔ macOS | Transport and rules complete. Needs the CloudKit container provisioned (below). |
| iOS / iPadOS | **No target exists.** The sync layer compiles for it as written; the app around it does not exist yet. |

### Before Mac-to-Mac runs

`AXTerm.entitlements` now declares CloudKit and the container
`iCloud.com.rosswardrup.AXTerm`. The container itself must be created against
the App ID — in Xcode, target AXTerm → Signing & Capabilities → iCloud →
CloudKit, tick the container. That is an account operation, not a code change.

### What an iOS target needs

Measured, not estimated — 307 Swift files in the app target, 32 of which use
AppKit or macOS-only frameworks:

- **Protocol core: 100% portable.** `AXTerm/AX25`, `Winlink/Protocol`,
  `Winlink/Session`, `Winlink/Store` — zero blocking files.
- **Winlink subsystem: 75 of 78 files portable.** The three blockers are
  `WinlinkComposeWindow` (NSOpenPanel), `WinlinkICS309Sheet` (NSSavePanel,
  NSPasteboard) and `WinlinkMessageDetail` (NSSavePanel, NSImage) — all with
  direct SwiftUI equivalents (`fileImporter`, `fileExporter`, `ShareLink`,
  `Image`).
- **The remaining 29 are the macOS shell**: the NSTableView-backed packet
  table, the Metal analytics graph, the terminal, menus, notifications, and
  serial-port discovery.
- **Transport on iOS**: `KISSLinkNetwork` (NWConnection) works as-is against a
  Direwolf or LinBPQ host over WiFi. `KISSLinkSerial` is IOKit and does not;
  a handheld TNC connects over BLE instead, which is new code.

So a mail-focused iOS/iPadOS companion is tractable — the whole mail stack
already compiles for it. A full AXTerm port is the packet table, the graph and
the terminal, which is a much larger piece of work and arguably not what
belongs on a phone.

---

## 10. Tests

`WinlinkSyncTests.swift` (27) and `WinlinkSyncEngineTests.swift` (11).

Merge rules: every kind classified; read monotonicity against a newer unread
write; `sent` never regressing; delivery merge symmetric across all 36 pairs;
offset following the claim holder rather than the larger number; provisional
seeds yielding wholesale; mailbox merge symmetric and idempotent; one-sided
MIDs kept.

Claims: expiry, holder exclusivity, deterministic tie-break, and the window
outlasting a measured session cap.

Engine, two fake devices over one in-memory transport: mail and attachments
crossing; read flags propagating; folders crossing by identity with
deliberately mismatched rowids; user folders created on arrival; drafts not
syncing; device-local kinds refused at the engine; no-account reported not
thrown; one unreadable record not blocking the rest; repeated passes
converging; orphan state ignored.

## Attributed data: what another station heard

The policy originally had three dispositions — `synced`, `deviceLocal`,
`sessionLocal` — and sharing observations between an operator's stations fits
none of them.

A packet the home rig heard is a real observation, and reading it from a
handheld is the whole point of the feature. But it is a measurement taken by
a *different antenna in a different place*. Merging it into local metrics
would produce df/dr/ETX describing neither station, which CLAUDE.md forbids:
routing metrics must be evidence-based and packet-derived from **this**
receiver. The existing `sessionLog` rationale already says as much — that
`WinlinkLinkQuality` refuses to treat a measurement taken elsewhere as a
prediction — and attributed data is that same reasoning applied to something
that *does* cross the wire.

Hence a fourth disposition:

```
case attributed(String)
```

Attributed state replicates but never merges. `replicatedKinds` (synced +
attributed) answers "may this cross the wire"; `syncedKinds` answers "may
this be folded into what this station believes". Conflating those two
questions is exactly how another antenna's numbers would end up in local
routing.

**Provenance is mandatory.** `WinlinkSyncProvenance` carries the observing
station, the device, its grid square and the time. Once a remote row is in
the database without it, the distinction cannot be recovered — so it rides on
the record rather than being inferred from context.

**Derived, not raw.** `StationActivityPayload` is a summary — callsign,
roles, first/last heard, frame count, airtime — not a packet log. A rolling
window of packets is tens of thousands of records; it would burn CloudKit
quota for data nobody reads twice, and the push-ledger bug fixed earlier
(re-pushing 26 unchanged records forever) is merely annoying at 26 and
expensive at 26,000.

**Keyed by observer *and* subject.** Two receivers hearing the same callsign
are two facts. Keying on the callsign alone would let whichever synced last
overwrite the other, silently discarding one antenna's view.

**A device ignores its own echo**, or its counts double on the very screen
built to keep the two apart.

**A separate screen.** `NetworkHistoryView` groups by the station that heard
each thing, labels every row "Heard by …", and says plainly that these
observations never affect local routing. Showing them beside local ones would
invite exactly the comparison that is invalid.

### Wiring

**Migration v11** adds `remoteStationActivity`, a table of its own. No query
that feeds routing inference can reach it, and that is structural rather than
a convention someone has to remember.

**Analytics pushes, the store does not pull.** `AnalyticsDashboardViewModel`
already derives the station directory from packets, inferred roles and the
identity mode; it hands the result down via `onStationDirectoryChanged`.
Having the store reach *up* for those inputs would put persistence in the
business of interpreting traffic, and a second derivation could quietly
disagree with what the operator is looking at.

**Publication is windowed** to seven days. Publishing the whole history every
pass would grow without bound and re-send facts that have not changed; the
push ledger would suppress the duplicates, but building them is still work
done for nothing.

**The toggle gates the source, not the sync.** `WinlinkContext` passes the
activity store to the controller only when `shareStationActivity` is on, so
the source is *absent* rather than present-and-idle — nothing is published,
and nothing arrives to store. Turning it off stops new observations leaving
immediately rather than at the next launch.

**Reachable from Mail → Directory → Other Stations** on iOS.
