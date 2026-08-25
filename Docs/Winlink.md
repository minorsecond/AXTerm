# Winlink Radiomail Subsystem

AXTerm includes a full Winlink client: an inbox/outbox/folders mail store,
a compose window with attachments, B2F mail exchange with RMS gateways over
**AX.25 packet** (primary) or **Telnet to the CMS** (fallback/testing), a
nearby-stations list from the Winlink CMS API, and a catalog browser for
requesting data products (weather bulletins etc.) over the air.

Everything lives under `AXTerm/Winlink/`; tests under
`AXTermTests/Unit/Winlink/`.

## Protocol layer (`Winlink/Protocol/`)

| File | Purpose |
|---|---|
| `LZHUF.swift` | LZHUF codec (adaptive Huffman + LZSS) with the B2F framing: `[crc16 LE][u32 LE length][bit stream]`. Port of la5nta/wl2k-go `lzhuf` (MIT). **Byte-exact** against wl2k-go fixtures in both directions — do not "clean up" the algorithm. |
| `B2FChecksums.swift` | `FBBCRC16` (Xmodem CRC-CCITT with two trailing zero bytes) and the negated-byte-sum used by proposal blocks and binary EOT trailers. |
| `B2Message.swift` | The B2 message unit: header lines (`Mid`, `Date`, `Type`, `From`, `To`, `Cc`, `Subject`, `Mbo`, `Body`, `File`…), ISO-8859-1 body with exact byte count, attachments. Parser validated against a real captured Winlink message. MID generation = first 12 chars of base32(MD5), per the reference clients. |
| `B2FProposal.swift` | `FC EM <mid> <usize> <csize> 0` lines, the `F> XX` block checksum (**includes each line's CR**), and `FS` answer parsing (`Y/+/N/R/-/E` accept/reject, `L/=/H` defer, `A/!/+<n>` accept-from-offset, capped at 999999). |
| `FBBBlockCodec.swift` | Binary body framing: `SOH len title NUL offset NUL`, `STX len data` (len 0 ⇒ 256; we send ≤125), `EOT checksum`. Incremental parser is chunk-boundary safe. |
| `WinlinkSID.swift` | `[WL2K-5.0-B2FWIHJM$]` parse/format. Gateways whose SID lacks `B2F` (e.g. B1F-only BPQ) are refused cleanly. |
| `WinlinkSecureLogin.swift` | `;PQ:`/`;PR:` challenge–response: MD5(challenge+password+fixed 64-byte salt), 8 decimal digits. Salt ported verbatim from paclink-unix via wl2k-go; vectors from wl2k-go tests. MD5 is an interop requirement of the protocol, not a security choice. |
| `B2FSessionEngine.swift` | The client-side conversation state machine — **pure sans-IO** (`handle(event) -> [Action]`, mirroring `AX25StateMachine`). Handles banner/prompt (including a `>` with no newline), handshake, ≤5-proposal batches, offset resume, turnover (`FF`), quit (`FQ`), timeouts, abort, and ignorable chatter (`;PM:`, MOTD). |

### Session flow (client side)

```
connect → [SID banner] [;PQ: challenge] … >           (gateway)
;FW: <call> [AXTerm-x-B2FHM$] [;PR: <response>]       (us)
FC EM … / F> XX   or   FF                             (us: proposals)
FS <answers>                                          (gateway)
<binary bodies for accepted proposals>                (us)
…more batches… then FF                                (us)
FC … F> XX  /  FF  /  FQ                              (gateway's turn)
FS <answers> → <binary bodies> → …                    (us accept/receive)
<batch drained> → our proposals or FF                 (turn passes to us)
FF → FQ → DISC                                        (clean shutdown)
```

Turn rule: whoever just **received** a batch of message bodies speaks
next — propose remaining traffic or send `FF`. The classic FBB trace is
`…data… → FF → FQ`. Waiting silently after receiving a batch leaves the
gateway holding a turn we never take; on the air (CMS via W0ARP-10,
2026-08-24) it gave up after ~70 s and DISCed, surfacing as "the gateway
closed the link" even though every message had transferred. A gateway
that volunteers `FF`/`FQ` right after its data is also handled — both
orderings complete the session. The all-declined-FS implicit turnover is
the same principle: nothing transferred, so the station with pending
mail takes the turn without an `FF` handshake.

## Transports and runner (`Winlink/Session/`)

- `WinlinkTransport` — protocol: `open() async throws`, `send(Data)`,
  `onReceive`, `onClose`, `close()`.
- `WinlinkAX25Transport` — claims the AX.25 session's delivered bytes
  exclusively via `AX25SessionManager.claimDelivery` (added for this
  feature): while claimed, `onDataReceived` (terminal line-splitter) and
  `onDataDeliveredForReassembly` (AXDP) are bypassed. PID `0xF0`, no AXDP
  envelope — B2F is wire-exact (spec §16).
- `WinlinkTelnetTransport` — TCP to `cms.winlink.org:8772`; the login
  preamble answers the `Callsign:`/`Password:` prompts (password is the
  fixed transport string `CMSTELNET` — real authentication is the B2F
  secure login, same as on the radio path).
- `WinlinkSessionRunner` (@MainActor, ObservableObject) — pumps
  transport ↔ engine ↔ store: executes `.send` actions, arms/cancels
  timers (stretched by expected airtime of L2-queued bytes, ~50 B/s
  assumed), persists delivery states, saves inbound mail, writes the
  session log, and reverts in-flight messages to `queued` on failure.
  Event dispatch is serialized against re-entrancy.

## Store (`Winlink/Store/`)

GRDB migration **v5** (`createWinlinkTables` in `WinlinkMigration.swift`,
registered in `DatabaseManager.migrator`).

- `winlinkMessage` — immutable content row (CLAUDE.md §7 append-only).
  Drafts are the only mutable stage; `queueDraft` freezes the row and
  `SQLiteWinlinkStore` rejects edits from then on.
- `winlinkMessageState` — mutable folder/read/delivery state
  (`draft/queued/sending/sent/failed/received`) + server-confirmed resume
  offset.
- `winlinkAttachment` — blobs, cascade on message delete.
- `winlinkFolder` — six seeded system folders + user folders (deleting a
  user folder archives its messages).
- `winlinkRMSStation`, `winlinkCatalogItem` — CMS caches (offline-first).
- `winlinkSessionLog` — append-only exchange history.
- `winlinkPartialBody` (migration **v7**) — partially received compressed
  bodies for B2F download resume (see below). Keyed by MID; rows expire
  after 14 days.

Inbound saves are idempotent by MID (gateways re-send after interrupted
sessions; the first copy wins). `WinlinkPersistenceWorker` (actor) keeps
writes off the main actor.

### Download resume (B2F checkpoint/restart)

When a session dies mid-body (remote DISC, timeout, abort), the engine
emits `.savePartialBody` with the compressed prefix received so far and the
runner persists it. On the next exchange the runner loads saved partials
into `Config.partialInbound`; when the gateway re-proposes the same MID at
the **same compressed size**, the FS answer becomes `FS !<offset>` and the
continuation is stitched onto the prefix. Rules, in order of trust:

- The gateway's SOH header offset is authoritative: equal to our request →
  stitch; `0` → gateway restarted, prefix dropped; less than held → prefix
  trimmed; **greater** than held → unfillable gap, session fails, nothing
  saved.
- **A resumed stream re-sends the six-byte LZHUF wire header** (CRC16 +
  uncompressed length) ahead of the continuation — field capture
  2026-08-24 (W0ARP-10, MID 6KFOMF87WJ8T) held it verbatim at all four
  resume seams. The engine strips it by exact match against the stored
  prefix's first six bytes, so a sender that continues verbatim instead
  still stitches correctly. Appending it was the compounding failure:
  each resume injected six junk bytes *and* inflated the next `FS !offset`
  by six, so the gateway skipped six real bytes — four resumes left the
  stream 24 bytes junk-heavy and 18 real bytes short, unrecoverable by
  any retry. Our own resumed *sends* mirror the gateway and re-send the
  header (`FBBBlockCodec.encode` with `offset > 0`).
- A re-sent header with the same length field but a different CRC16 means
  the gateway restarted from a **different compression** of the body:
  nothing held can ever stitch to it, so the session fails at the seam
  (six bytes in, not after a doomed full download) and the stale partial
  is discarded.
- An interruption within the first six bytes of a resumed stream is
  ambiguous (header mid-arrival vs. stream bytes): nothing new is saved
  and the stored prefix survives untouched.
- The stitched stream's own LZHUF CRC is the final arbiter. A failed decode
  of a stitched body discards the stored partial so the next attempt starts
  clean, and the assembled body is written to
  `~/Downloads/AXTerm Diagnostics/<MID>-<stamp>-resumed<N>-of<M>.b2fbody`
  for offline analysis — that capture is what proved the header re-send.
- Bytes from a corrupt stream (EOT checksum or framing failure) are never
  saved; an existing stored partial survives such a session untouched.
- A re-proposal with a different compressed size is a different encoding —
  the partial is discarded and the message accepted fresh.

## CMS API (`Winlink/API/`)

`WinlinkCMSClient` (api.winlink.org, JSON): `/gateway/proximity`
(grid square → packet gateways with distance/heading/frequency/baud) and
`/inquiries/catalog` (data products). The access key defaults to the key
published in the open-source Pat client and can be overridden in
Settings; it is stored in the Keychain and scrubbed from error text.

## Attachment pre-compression

LZHUF — the only compression B2F puts on the wire — is 1988 LZSS with a
2 KB window: redundancy further apart than 2 KB is invisible to it.
`AttachmentCompressor` zips large compressible attachments at attach time
(deflate, 32 KB window) into ordinary single-entry archives any tool
opens; LZHUF then costs nothing on the dense bytes. Routinely halves what
crosses a 1200-baud channel for large text.

Never compressed: files under 512 B, already-dense extensions (media,
archives, office formats), anything saving less than 10% (the recipient
pays a rename to `.zip` — a marginal win doesn't cover it), and **xml —
Winlink form workflows key on exact attachment names**. The compose chip
shows `original → zipped` sizes with a right-click "Send Original".

## Catalog requests

Winlink data products are requested with an ordinary message:
`To: INQUIRY`, `Subject: REQUEST`, type `Inquiry`, body = one InquiryId
per CRLF line. The catalog sheet builds and queues this; responses arrive
as normal mail on a later exchange.

The catalog *index* itself has two sources feeding one cache
(`winlinkCatalogItem`):

- **Internet** (needs a personal access key): `refresh()` via the CMS
  web service.
- **Radio** (key-free): body `LIST` to `INQUIRY`; the SERVICE robot
  replies with a plain-text table (~1450 products, ~180 KB). The reply
  is parsed by `WinlinkCatalogListReply` and ingested into the cache —
  at receive time by the session runner, and retroactively by the
  catalog view model when the cache is empty but a LIST reply is
  already in the mailbox. Format quirks (field capture 2026-08-24):
  subjects that fill their column run flush against the size with no
  separating space, and buoy subjects embed `"` characters, so the
  last quote before the size terminates the subject. A reply that
  parses to zero items is ignored rather than wiping a good cache.

### Browsing the catalog

~1450 products across ~126 category codes is unbrowsable as a flat list,
so `WinlinkCatalogTaxonomy` turns the codes into a two-level hierarchy
that `WinlinkCatalogSheet` renders as a sidebar (families → categories)
beside a product list.

Grouping is **mechanical** — a prefix decomposition of the gateway's own
code — so a refresh that adds new codes slots them in without a code
change. `WX_US_*` → United States Weather, `WX_*` → World & Marine,
`METAREA*` → marine zones, `WL2K_*` → Winlink System, `SAT_*` /
`PROPAGATION` / `AURORA` → Satellite & Propagation, everything else →
Other. Order matters: the `WX_US` test must precede the general `WX` one.

Token expansions come from two sources only, never from a guess: the
USPS state abbreviations, and codes whose meaning was read off their own
items' subjects in the 2026-08-24 capture. Cases the data settled:

- `WX_US_DE` is **Delaware**, but `WX_BALT_DE` is **Germany** — inside
  the United States family the state map outranks the token map.
- `METAR`, `HONDURAS`, `NICARAGUA`, `ARCTIC_ICE`, `INDIAN_OCEAN` and
  `S/PACIFIC_WX` carry no `WX` prefix but are weather; they are listed
  explicitly so "Other" does not fill with forecasts.
- METAREA leaves keep the full code (`METAREA XIV`, not a bare `XIV`)
  and sort by numeral value — alphabetically `IX` falls between `III`
  and `V`.
- Unrecognized codes keep their raw token capitalized, and every row
  shows the raw code beside the friendly name, so nothing the gateway
  said is hidden or invented.

Sidebar families are **collapsed by default**: six family headers fit on
screen at once, 126 category rows do not. A search unfolds every family
that still has matches — collapsed sections would otherwise hide the
results — and clearing it re-collapses them.

Search runs across subject, InquiryId, raw code, **and** the friendly
category name — so "alaska" finds `WX_AK_COAST`, whose subject and code
both omit the word. It narrows the sidebar counts too, not just the list.
If a search excludes the category being viewed, the pane falls back to
All Products rather than going blank.

### Favorites

Starred products live in their own table, `winlinkCatalogFavorite`
(migration v9), **not** as a flag on `winlinkCatalogItem`.
`replaceCatalogCache` deletes every product row on each refresh, so a
flag there would be erased by the next LIST reply.

A consequence worth stating: a favourite can name a product the current
index no longer carries. `WinlinkCatalogViewModel.favorites` keeps the
star regardless — the product disappearing is information, not
corruption — while `favoriteItems` lists only what the index actually
has, and the empty state distinguishes "nothing starred yet" from "your
starred products are not in this index". Re-starring is idempotent and
does not reset `addedAt`.

**Two scopes, two behaviours.** Favorites is a browsing scope and
narrows with the search, like All Products. Selected is the request
basket and deliberately ignores the search (`selectedItems`): narrowing
it as the operator types would look exactly like selections being lost.
Every sidebar count matches what clicking that row shows.

### Airtime estimates

Every size in the catalog UI is paired with an airtime estimate, because
a size in kilobytes does not tell an operator whether a request is a
minute or an hour. `WinlinkAirtimeEstimate` computes it, and is explicit
about which half of the answer is evidence.

**Throughput is measured.** `WinlinkLinkQuality.effectiveBytesPerSecond`
already derives bytes/second from AXTerm's own session logs, per gateway
*per frequency*, and the units line up exactly: `B2FSessionEngine`
accumulates `outbound.compressed.count`, so the logged bytes are the
same compressed wire bytes the estimate divides by — a measured rate
substitutes with no conversion. `WinlinkMailView` passes the first
ladder rung (callsign + frequency), which is the link `startExchange`
will actually try. `RMSStationsViewModel.reloadLinkQuality()` runs at
init and after every exchange, so the figure is current.

**Compression is not.** `FC EM <MID> <uncompressed> <compressed> 0`
carries both sizes on every proposal, but only the compressed side is
persisted, so there is no history to average. 3:1 stays an assumption —
conservative against the 4.2:1 the 2026-08-24 capture achieved on
catalog text, and deliberately so, since fax and radar products are not
text. Making this adaptive needs a migration to accumulate uncompressed
bytes alongside.

Rules the estimate inherits from `WinlinkLinkQuality` and must not
soften:

- A rate is **never borrowed across frequencies**. The same gateway
  "behaves nothing alike" at 1200 and 9600 baud. A cap *is* carried
  across them, because a cap is a property of the gateway's software.
- A measurement taken elsewhere is **context, never a prediction**
  (`appliesHere`). The tooltip reports it and still uses the default.
- A 4-character grid square carries 60 km of uncertainty, so a
  grid-only operator never reaches `.here` and never gets a measured
  rate. Six characters (3 km) does qualify. This is intended: the
  estimate must not claim precision the position does not have.
- Below ten seconds of measured traffic there is no rate at all.

The footer states which basis is in play (`provenance`: "measured 34 B/s
to K0NTS-10" or "assumed 30 B/s"), the tooltip explains why in a
sentence, and selections estimated at ten minutes or more mark the clock
amber.

**Session caps.** `longestSessionSeconds` records that W0ARP-10
disconnects at ~17 minutes. When a selection needs more airtime than the
gateway has ever granted, the footer says how many exchanges it will
take — a warning the clock alone cannot give, since the transfer resumes
rather than fails. Sessions shorter than a minute are not treated as
evidence of a cap; every session is short when there is nothing to send.

### Rendering received products

`WinlinkMessageDetail` renders a received body natively when it
recognises the format, and falls back to monospaced raw text otherwise.
Two recognisers exist today, both following the same rule: **parse
structurally, never semantically, and refuse rather than half-render.**

- **Winlink forms** — `WinlinkReceivedForm` parses the
  `RMS_Express_Form_*.xml` attachment into `WinlinkReceivedFormView`.
- **NWS tabular state forecasts** (`SFTxx`) —
  `NWSTabularForecast.parse` turns the fixed-width product into a real
  table: one column per forecast day, one row per city, grouped by the
  product's own `...REGION...` headers.

For the tabular forecast the structural rules are:

- The day count comes from the product's own `FCST` header row, not a
  constant.
- Columns split on runs of **two or more** blanks. Single spaces are
  internal to values — `Aug 25`, `COLORADO SPRINGS` — and a naive
  whitespace split would tear those in half and take the column count
  with them. Character offsets are not used either, since column widths
  vary between offices.
- A place is a non-data line followed by exactly three data rows
  (weather / `low/high` / `night/day` PoP). A place whose cadence breaks
  is **dropped, not padded** with invented cells, which is also what
  discards the legend block above the table.
- `$$` terminates the product; the Winlink footer after it is not
  forecast data.
- `MM` and unparseable values become nil and render as "—", never as a
  temperature. `00` is a real value, not a gap.
- Weather abbreviations expand only when present in
  `NWSTabularForecast.weatherNames`; `SUNNY`, `PTCLDY`, `TSTRMS` and
  `VRYHOT` are confirmed against the 2026-08-24 SFTCO capture and the
  rest follow the same six-character convention. Anything unrecognised
  renders **verbatim** with a neutral icon.

Cell tooltips give the value and its provenance — product ID, issuing
office, and issuance time — so a stale forecast is recognisable as
stale. The raw product stays one disclosure away and is never
discarded: it is what crossed the air, and if it and the table ever
disagree, the table is wrong.

## Grid-down operating

The Winlink features above all assume infrastructure: an RMS gateway that
forwards to the CMS over the internet. When that is gone, the following
is what still works.

### Peer-to-peer (answering role)

`B2FSessionEngine` plays both halves of the conversation, selected by
`Config.role`:

- `.initiator` calls a gateway — waits for the remote banner, handshakes,
  then proposes.
- `.answering` **speaks first** (SID + prompt), then listens, because in
  B2F the station that just handshook proposes first.

The roles are far less different than they look. Everything after the
handshake is already symmetric — the second half of an initiator session
*is* answering behaviour — so only the opening differs. The answering
side sends no `;PQ:` challenge and expects no `;PR:`: P2P carries no CMS
account to authenticate against, and demanding a password nobody can
verify would just break the exchange. A caller whose SID lacks `B2F` is
refused rather than risking a B1 exchange, and a caller that connects
and says nothing is timed out — in an emergency the frequency is shared.

**Arming is deliberate.** `WinlinkSettings.p2pListenEnabled` is off by
default. An armed station accepts mail from anyone who calls and
transmits in reply with no operator present: right for an activation,
wrong for everyday operating. `WinlinkP2PListener` holds the policy,
separate from the transport and the state machine so it is testable
without a radio, and every refusal is *explainable* — a station that
silently ignores callers is indistinguishable from a broken one, so
declined calls are noted in the exchange transcript via
`WinlinkSessionRunner.note`.

Addressing follows the SSID collision this project already documents: a
configured SSID (`K0EPI-7`) answers only that exact address, while a bare
callsign (`K0EPI`) is a wildcard over its own SSIDs. Otherwise a mail
station would hijack calls meant for a node on another SSID.

Wiring: `SessionCoordinator.onInboundSessionConnected` is a plain
callback so the coordinator needs to know nothing about mail;
`WinlinkAX25Transport` already reuses an existing connected session, so
answering needs no new transport — `open()` finds the session and
returns.

### ICS-309 Communications Log

Every activation ends with someone asking for the message log, and unlike
the rest of the station's records it **cannot be reconstructed
afterwards**. `ICS309Log` builds one from traffic already stored, so it
is a report rather than a thing to maintain.

- Times render in **UTC** — what the traffic carries, and what an agency
  reconciling logs from several stations can actually use.
- Only messages inside the operational period are included: a log whose
  contents span a different window than its header claims is worse than
  no log.
- Drafts are excluded. A message composed but never sent is not traffic,
  and logging it would overstate what the station did.
- Entries sort by time then MID, so two exports of one incident are
  byte-identical.
- One message to several addresses stays one row — it was one
  transmission.
- CSV output is RFC 4180 quoted; message subjects routinely contain
  commas, and an unescaped one silently shifts every later column.

### Outage kit (pre-staging)

`WinlinkOutageKit` picks the catalog products worth having on disk
*before* the path you would use to request them is gone. It is
deliberately biased toward small, durable, operationally load-bearing
documents over forecasts:

| Reason | What | Why |
|---|---|---|
| `operatingPlan` | `ARES_RACES`, `HF_NETS` — ICS-205s, net schedules | Tells you where to find other stations with no infrastructure; useless to request afterwards |
| `reference` | Named `WL2K_HELP` documents only | The category holds 20; staging all would cost more airtime than the plans that matter |
| `propagation` | `PROP_WWV` (482 bytes) | What the bands are likely to do |
| `localWeather` | `WX_US_<state>` for the operator's own state | Perishable, but the first thing anyone asks for; optional |

Bulk weather — radar, fax — is excluded on purpose: enormous, and stale
within the hour. With no state configured, **no** local weather is
staged rather than another state's. Selection is deterministic, so two
operators staging from the same index queue the same request, and it
surfaces as an "Outage Kit" scope in the catalog browser where the
existing Select All → Request flow queues it.

### Field status (pre-flight)

Station Tools → **Field Status** gathers three things that otherwise live
in three places, because the moment they matter is the moment nobody
wants to go looking for them.

`WinlinkReadiness` is a pure function of a snapshot — no store, no
Keychain, no clock — so it is testable without a radio. Nothing it
reports is new capability; the value is having it answered before
departure. Two judgements worth stating:

- Missing gateway **and** P2P off is `blocked`: the station can compose
  mail and never move it. P2P alone is only a `warning` — that is a
  legitimate grid-down posture, not a failure.
- A missing password is a `warning`, not a blocker: CMS sessions need
  one, P2P does not.
- "Settings that have never completed a session are a plan, not a
  capability" — hence the *proven path* check.

Every non-ready check carries a remedy. A red dot with no remedy just
moves the problem, and there is a test asserting none exist.

`WinlinkGatewayHours` answers *when* a gateway actually answers, from
this station's own session log, bucketed by **local** hour because an
operator plans against a wristwatch. Definitions of "counts as evidence"
and "answered" come from `WinlinkLinkQuality.isLinkEvidence` /
`wasAnswered`, so the Link column and this profile can never disagree.
Below `minimumTotalAttempts` it says so rather than dressing three
sessions up as a schedule, and an hour never tried renders differently
from an hour tried and failed.

`SolarEvents` and `MoonPhase` compute sunrise, sunset, civil twilight,
solar noon, gray-line windows, and moon illumination **locally** from
lat/lon — no network, gateway, or radio. On a summit "how long until
dark" outranks most of what a radio can say, and gray-line windows are
when a marginal HF band is most likely workable. Polar day and night are
real answers, not errors. Accuracy is the standard low-precision
equations: about a minute at mid latitudes, ample for planning a descent,
**not** a navigational almanac.

Three implementation notes, all of which were bugs first, and the third
is the instructive one:

1. The day number must be **rounded to a whole day**. Left fractional,
   "solar noon" comes back just after whatever instant you asked about.
2. The longitude term must be **reapplied** to the mean-noon value
   afterwards. Drop it and every meridian collapses onto the same transit.
3. The longitude term appears **twice, with opposite signs**, and getting
   the inner one wrong is invisible in the output. Picking the day is
   `round(J − J2000 + λ/360)`; placing the transit inside that day is
   `− λ/360`. With the inner sign flipped, an afternoon in the western
   hemisphere rounds to the *next* day — and because the result renders
   as a time of day, tomorrow's sunset looks identical to today's. It
   surfaced only as "32h 36m of daylight left" (field report 2026-08-24,
   Denver, 11:07 local).

That third bug survived a suite of physical-invariant tests — equinox day
length, rise/set symmetry, day length vs. latitude in both hemispheres,
solar noon near 12:00 UTC on the prime meridian — because every one of
them is **date-agnostic**: they compare times of day, or relative
quantities, and a whole day's offset passes them all. The tests that
catch it assert the events belong to the day that was *asked about*:
solar noon within twelve hours of the instant, sunrise and sunset
straddling a midday instant, and the same answer whenever you ask within
a day. A correct invariant is only useful if it constrains the axis the
bug lives on.

### Position reporting (POTA/SOTA self-spotting)

Station Tools → **Report Position** queues the existing Position Report
form (a message to `QTH`) prefilled from a live GPS fix. Winlink posts it
to the winlink.org map, which makes it the self-spotting path when there
is no cell coverage — the portable-activation case. The comment field is
remembered in `@AppStorage`, since an activation reference (`POTA
K-1234`) stays the same all day.

The wire format is deliberately the existing form's, not a new one, so
what leaves the station is what Winlink expects.

### Station map (the scope)

Station Tools → **Station Map** opens a real window — resizable, zoomable
and full-screenable, which a sheet is not — plotting every cached RMS
gateway around this station, coloured by *measured* link quality.

There is a second map at the app level: the **Map** navigation area shows
every station this receiver has *heard*, which is a different and larger
set. See "Stations heard" below.

**Two renderings, one model.** `StationMapView` draws real geography with
MapKit and is the default — it is what people mean by "map".
`StationScopeView` plots bearing and range with no base map at all, and
is the mode that still works when there are no tiles to fetch. Both are
driven by the same `StationScope`, so anything that can build one gets
both for free, and the operator picks per-window (remembered in
`@AppStorage`).

Every gateway's position comes from the grid square already in the
station cache, so the *positions* never need the network — only the map
tiles do. That is why the scope exists rather than being a consolation
prize: for "can I reach that gateway", bearing, distance and measured
quality are the information, and they survive the loss of everything
else.

This is also the question the winlink.org map cannot answer — that map
knows where gateways are, but not your ETX, your terrain, or which ones
have ever answered you.

Three layers, and the split is what makes it reusable:

- `GreatCircle` — distance and initial true bearing. One implementation
  for everything that asks "how far, which way".
- `StationScope` — a view-free model: sites with range, bearing, a
  semantic `Signal`, and `unitPoint(maxRange:)` for plotting. No colours,
  no fonts, no view types, so **anything** with positions can build one.
  NET/ROM neighbours and heard stations get this rendering for free.
- `StationScopeView` / `StationMapView` — the renderers, neither of which
  knows anything about Winlink.
- `MapRegionFit` — framing arithmetic, kept out of MapKit and out of any
  view so it is testable: a span of zero when every station shares a grid
  square, or a region that clips the furthest gateway, are the mistakes
  that live here.

Rules worth keeping:

- A station whose position is unknown is **dropped, never guessed at**.
  Plotting it in the wrong place is worse than not plotting it.
- Colour is measured behaviour, not advertised capability. A gateway
  never worked is `unknown` (faded, grey) — different from one that
  answers badly, and it must not draw the same.
- One dot per **callsign**, not per frequency: the same gateway on three
  frequencies is one place, and the frequencies belong in its label.
- The outer ring is a round number from `ringSteps`, not whatever the
  furthest station happens to be, and there are at most three inner rings
  so the plot reads as a scale rather than a target.
- Sites sort nearest-first with ties broken by identity, so two builds of
  the same data draw identically.

### Stations table: paths and visibility

`WinlinkStationPreferences` holds per-link operator preferences,
persisted in `WinlinkSettings.stationPreferences`.

**Keyed by link, never by callsign.** The same gateway on 145.050 and
441.075 is two radios, two paths, and often two different answers about
reachability. A preference stored per callsign would leak a VHF digi
route onto a UHF link.

- **Digipeater path.** Set it inline in the table's Path column; it is
  remembered and used every time that link is worked. Accepts commas,
  spaces or both, uppercases, and caps at the AX.25 limit of 8 digis —
  dropping the excess here beats failing at transmit time. Blank means
  direct, and "direct" has exactly one stored representation (the key is
  removed, not set to `""`). The exchange falls back to the global
  `gatewayPath` only when a link has no stored path.
- **Hidden links** are hidden from the *table*, never from the data. The
  record stays cached and its link quality keeps accumulating; "Show
  Hidden Links" restores them. Hiding lives in the row context menu
  rather than a column, since a permanent button would cost width on
  every row forever.
- **Frequency filter** for a radio that lives on one frequency. An empty
  set means *show everything* — the only reading that degrades safely if
  the set is ever lost. Selecting every frequency collapses back to the
  empty set, so a frequency that appears in a later refresh is shown
  rather than silently excluded.

Whenever a filter is withholding rows the header says "N of M", because
silent truncation reads as "that is everything" when it is not.

### Callsign directory (source-agnostic)

Gateways come with grid squares from the CMS, so they plot offline. The
23 callsigns in the Stations sidebar do not — those are heard on the air
with no position attached, and a directory is the only way to place them.

`CallsignDirectory` is the protocol; **AXTerm never depends on one
service**. `HamDBDirectory` is the first implementation, and the SQLite
cache is another one that happens to be local.

`CallsignDirectoryChain` tries sources in order and returns the first
real answer. Order is policy: cache first costs nothing when the network
is gone. A source that *throws* does not stop the chain — one service
being down must not mask another that works — and an error surfaces only
when nothing at all answered, since silence would read as "no such
station".

**HamDB specifics, verified live 2026-08-24** (neither is guessable):

- The **versioned** path is required. `api.hamdb.org/{call}/json/{app}`
  answers `302` with an empty body; `api.hamdb.org/v1/...` answers.
- A miss is **HTTP 200** with every field set to the literal string
  `"NOT_FOUND"` — `grid`, `lat`, `name`, all of them. Parsed naively that
  yields a station called NOT_FOUND in grid NOT_FOUND, so the sentinel is
  detected explicitly rather than trusted to fail at conversion.

Other rules that cost a round trip or a wrong answer if missed:

- Queries use the **base callsign**. A licence has no SSID: `W0ARP-10` is
  the gateway, `W0ARP` is the licensee, and querying the former returns
  nothing — indistinguishable from "no such station".
- Tactical aliases (`MAIL`, `BEACON`, `ID`, `NODE`) fail the plausibility
  check and never reach the network. They are destinations, not licensees.
- Answers are **cached permanently and never expired on age**. A licence
  address changes rarely, and a stale answer beats no answer when the
  network that would refresh it is gone. Age is recorded so the UI can
  say how old it is; nothing deletes on age.
- Decoding is separated from fetching, so the awkward parts are tested
  against captured payloads with no network involved.

**Opt-in** (`WinlinkSettings.callsignLookupEnabled`, off by default): a
lookup tells a third party which stations this operator is hearing.
Public licence data, a small disclosure — but a disclosure, and not one
to make silently.

### Stations heard (the Map area)

The Winlink map shows gateways, which come with grid squares. The **Map**
navigation area shows everything the receiver has heard, which mostly
does not.

`HeardStationMap` resolves each heard callsign against two sources, in
order of specificity:

1. The **RMS cache** — a gateway's own grid from the CMS, keyed by full
   callsign *with* SSID. More specific than its licensee's mailing
   address, so it wins.
2. The **callsign directory** — keyed by base callsign, so `KB5YZB-7`
   resolves through `KB5YZB`.

The output is deliberately **two lists**: placed and unplaced. A station
heard four hundred times that nobody can locate is not an omission to
hide — it is usually the row worth looking at, and the header says "12 of
23 placed" rather than quietly showing twelve dots.

For a heard station, **recency is the signal** — it is the only thing the
receiver actually measured. Active within the hour, fading over a day,
faded past that. `lookupCandidates` offers only unplaced, plausible
callsigns to the directory, so tactical aliases and already-placed
gateways never cost a round trip.

### Node aliases, and what a position is *of*

Via paths are full of tactical names — `DRLNOD`, `HORSE`, `EATON`,
`YZBBPQ`. None is a licence, so no callsign directory will ever hold
one. But stations **announce** their aliases in ID beacons this receiver
already stores:

```
KE0NCQ/R DRL/D DRLBBS/B DRLNOD/N       → DRLNOD is KE0NCQ
W1VAN/R W1VAN-7/D HORSE/N              → HORSE  is W1VAN
NODE: YZBBPQ:KB5YZB-7, Aurora, CO      → YZBBPQ is KB5YZB-7
```

`NodeAliasParser` reads both forms; `NodeAliasStore` accumulates and
persists them, fed from ID/beacon frames. `KB5YZB-1/B` is deliberately
*not* an alias — it is an SSID of the same licence, and recording it
would make a callsign resolve to itself.

**But an alias is not co-located with its operator.** A NET/ROM node
lives on a hilltop or a repeater site; the licence address is a mailing
address. So `PositionConfidence` distinguishes three things that a
boolean used to conflate:

| Confidence | Means | Drawn |
|---|---|---|
| `exact` | A coordinate consistent with everything else known | Solid |
| `gridSquare` | Centre of a square the station itself registered | Solid |
| `inferredFromOperator` | Position of a *different entity* — a node placed at its operator's address | **Hollow, dashed** |

**Precision is not accuracy**, and treating the precise value as
automatically better is how a map lies confidently. A licence address is
exact to seven decimals and describes the licensee; an RMS grid is coarse
and describes the gateway that registered it. So an exact coordinate is
used as a *refinement only when it agrees* with the coarser claim —
`gridContains` tests whether it falls inside the registered square. When
they disagree, the source about the right entity wins and the tooltip
says they disagree rather than silently resolving it.

For W0ARP that check passes: hamdb says `DM79ql`, the CMS says `DM79QL`,
and the licence address falls inside it — two independent sources
agreeing, so the refinement is legitimate.

Aliases whose operator is not yet located are listed **unplaced rather
than dropped**, and `lookupCandidates` substitutes the operator's
callsign, since looking up "DRLNOD" would fail.

## UI (`Winlink/UI/`, `Winlink/ViewModels/`)

- `Mail` navigation area (⌘5), unread badge on the sidebar item.
- Three panes: folder sidebar / message table (search, delivery badges) /
  reading pane (attachment save, reply/reply-all/forward with quoting).
- **Reading-pane placement** is an operator preference, remembered in
  `@AppStorage("winlink.readingPaneLayout")`: right (the classic
  three-column layout), bottom, or hidden. Bottom exists because the
  natively-rendered products are wide — a seven-day tabular forecast
  is eight columns and unreadable in a side pane.
- Occasional actions live in a **Station Tools** overflow menu
  (`ellipsis.circle`) rather than each taking permanent toolbar space:
  reading-pane placement, open-in-window, and the ICS-309 log. The
  toolbar carries what an operator reaches for every session; everything
  else is a menu.
- **A message opens in its own window** on double-click, from the row's
  context menu, or with ⌘O from the reading pane.
  `WinlinkMessageWindow` owns its own mailbox view model rather than
  borrowing the mail tab's, since the window outlives the tab; reply and
  forward from it go through the same persisted-draft path, so drafts
  still survive a restart. A message deleted while its window is open
  shows a "no longer in the mailbox" state rather than stale content.
  `WinlinkMessageDetail` takes the message directly instead of reading a
  view model's selection, which is what lets one view serve both places.
- Compose is a separate window (`winlinkCompose` scene) that always edits
  a **persisted draft row**, so drafts survive restarts. Live 120 kB size
  gauge; addresses normalize to callsigns or `SMTP:` internet addresses;
  bodies are validated as ISO-8859-1 with CRLF endings.
- Stations tab: cache-first CMS proximity list with Set Gateway /
  Exchange actions.
- Settings → Winlink: grid square (validated Maidenhead), Keychain-backed
  password + API key, search radius, transport preference.
- All metric/tooltip copy is centralized in `WinlinkCopy.swift`
  (CLAUDE.md §11).

## Testing

~110 Winlink tests. Highlights:

- **LZHUF interop fixtures** (`LZHUFFixtures.swift`, from wl2k-go, incl. a
  real captured B2F message with a JPEG attachment) — round-trip alone
  cannot catch a self-consistent-but-wrong port; byte-exact comparison
  can. Regenerate per the header comment if ever needed.
- `B2FSessionEngineTests` — scripted dialogs, including full sessions fed
  one byte at a time.
- `WinlinkSessionRunnerTests` — end-to-end exchanges against an
  in-process scripted RMS (real engine/codecs/store; only the link is
  fake), including mid-session link drops.
- `SessionDeliveryClaimTests` — proof that claimed sessions bypass the
  terminal and AXDP.
- `SQLiteWinlinkStoreTests` — real migrator on in-memory queues; draft
  immutability, duplicate MIDs, cascades.
- `WinlinkCMSClientTests` — stubbed URLProtocol; key-redaction test.

End-to-end without RF: run a Telnet exchange against the live CMS (send a
self-addressed message; run a catalog request and poll again). On RF: the
local RMS (`K0NTS-10` per its ID beacon) is a natural first target.

## Station identity and location (`AXTerm/Station/`)

- `StationProfile` — operator name/title/organization/phone/email plus
  address fields (UserDefaults). The Winlink password is only a
  credential; the CMS never shares account identity over B2F, so this
  profile is the local source of truth that auto-fills forms.
- `StationLocationService` — one-shot GPS via CoreLocation (location
  entitlement + usage strings) with fallback to the configured grid
  square's center. Portable: Winlink compose, the packet-terminal
  compose bar, forms, position reports, and SailDocs spot forecasts all
  pull from it. `StationLocationFormat` renders the Winlink
  insertion-tag position formats.

## Forms (`AXTerm/Winlink/Forms/`)

Native SwiftUI forms over the official Winlink Standard Templates
(v1.1.20.0, embedded verbatim in `WinlinkFormTemplateTexts.swift`):

- `WinlinkFormEngine` parses template control lines (`To:`/`Subject:`/
  `Msg:`), substitutes `<var x>` and the official insertion tags
  (`<MsgSender>`, `<DateTime>`, `<UDTG>`, GPS formats…), and builds the
  `RMS_Express_Form_<viewer>.xml` attachment (form_parameters + sorted
  lowercased variables) so Winlink Express renders the official form.
- Catalog: Winlink Check-in / Check-out, ICS-213 General Message, Field
  Situation Report, Severe Weather Report, and the Position Report
  (plain text to `QTH` — how positions reach the Winlink map).
- Fields auto-fill from `StationProfile` and a live position fix taken
  when the form opens. Received messages carrying form XML render as a
  native field card in the reading pane (any form, not just ours).

## Send progress

Delivery claims carry an ack tap; `WinlinkAX25Transport` computes
delivered = submitted − (pending queue + in-flight window) exactly from
session state, and Telnet counts socket writes. The runner publishes
`WinlinkExchangeProgress` (per-message compressed-byte totals, baselined
so handshake bytes don't pollute the bar); the toolbar card shows phase,
a determinate bar, bytes, rate, and ETA.

## Address book

Migration v6 (`winlinkContact`): full contact records (callsign and/or
internet address, phone, org, grid, mailing address, notes, favorites,
recency). Contacts tab in the Mail area; compose To/Cc fields suggest
matching contacts as chips; queueing bumps recency; unknown senders get
a one-click "add to contacts" in the reading pane.

## SailDocs and utilities

The catalog sheet's "Internet (SailDocs)" source builds requests to
`query@saildocs.com` (web-page-as-text, spot forecast from the station
position, raw commands) — the community's internet-over-Winlink path,
useful precisely because it needs no access key. The exchange menu can
queue a loopback message to the `TEST` echo bot. The Winlink catalog
index itself is requested over the air (`LIST` to `INQUIRY`) since the
catalog web service requires a personal key.

## Empirical link quality (the Stations "Link" column)

The CMS directory says a gateway exists, how far away it is, and what baud
it advertises. It cannot say whether *you* can work it from *here* — that
depends on both endpoints, terrain, antennas, and what else is on the
channel. `WinlinkLinkQuality` answers that from AXTerm's own session log.

**Link identity is callsign + frequency**, matching
`WinlinkRMSStationRecord.id`. W0ARP-10 answers on 145.030 and 145.050 at
1200 bd and on 441.075 at 9600 bd; merging them would report the fast
link's throughput on a slow link's row. Telnet sessions are excluded
entirely — they reach the CMS over the internet and prove nothing about
RF.

**What is counted**

| Field | Meaning |
| --- | --- |
| `attempts` / `answered` | Every connect vs. those where a link came up. A gateway that never answers is a different problem from one that answers and struggles, so the two are never collapsed. |
| `effectiveBytesPerSecond` | Payload ÷ wall-clock connected time. Retries, ACK waits, and a busy channel all count against it. Nil below 10 s of link time — a two-second session is not a measurement. |
| `longestSessionSeconds` | Reveals an enforced session cap (W0ARP-10 disconnects at ~17 min), which bounds one attempt no matter how good the path is. |

"Answered" is inferred from evidence rather than the result string: any
byte exchanged, or any failure that is not a connect failure, means the
gateway was there.

**Geography (migration v8)**

Every session log records where the operator was — `obsLatitude`,
`obsLongitude`, `obsGrid`, `obsSource` — resolved in the background at
exchange start so nothing delays keying the radio. `Placement` grades the
result rather than assuming it:

| Distance from the nearest sample | Placement | Shown as |
| --- | --- | --- |
| ≤ 2 km | `.here` | Full colour; "describes this path" |
| ≤ 15 km | `.nearby(km)` | Full colour, distance named, ridge caveat |
| > 15 km | `.elsewhere(grid, km)` | Grey, explicitly "not a prediction" |
| no position on the samples | `.unknown` | Grey; says it cannot tell |

Two rules keep this honest. The **nearest** sample decides placement — if
you have ever worked the gateway from here, that is the relevant evidence
and a stray sample from a trip must not disqualify the row. And a
grid-square position can never claim more precision than its square: a
6-character locator floors the distance at 3 km (half a subsquare
diagonal), so it reports `.nearby`, never `.here`.

Time and geography stay orthogonal. A stale nearby sample and a fresh
distant one are different kinds of doubt; collapsing them into one score
would hide which applies. Age is always shown, and samples past the
90-day horizon are dropped.

Tests: `WinlinkLinkQualityTests`.

## Known limitations / future work

- B1F-only gateways are refused (clean error) rather than spoken to.
- No P2P (client-to-client) sessions yet; RMS/CMS only.
- Pacing: bulk B2F sends ride the normal session queue; §4.3 token-bucket
  enforcement is a codebase-wide gap (spec §16 checklist).
- The Link column is descriptive only — it does not yet reorder the
  gateway ladder automatically.
- FBB's checksum is one running sum over the whole body, verified at EOT,
  so a corrupt stream cannot be localized and the whole prefix is lost.
  Per-block verification would need a protocol extension.
- The community CMS key only covers /gateway/status.json; users with a
  personal key can also refresh the catalog over the internet.
