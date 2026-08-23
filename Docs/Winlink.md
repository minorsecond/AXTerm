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
FF → FQ → DISC                                        (clean shutdown)
```

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

Inbound saves are idempotent by MID (gateways re-send after interrupted
sessions; the first copy wins). `WinlinkPersistenceWorker` (actor) keeps
writes off the main actor.

## CMS API (`Winlink/API/`)

`WinlinkCMSClient` (api.winlink.org, JSON): `/gateway/proximity`
(grid square → packet gateways with distance/heading/frequency/baud) and
`/inquiries/catalog` (data products). The access key defaults to the key
published in the open-source Pat client and can be overridden in
Settings; it is stored in the Keychain and scrubbed from error text.

## Catalog requests

Winlink data products are requested with an ordinary message:
`To: INQUIRY`, `Subject: REQUEST`, type `Inquiry`, body = one InquiryId
per CRLF line. The catalog sheet builds and queues this; responses arrive
as normal mail on a later exchange.

## UI (`Winlink/UI/`, `Winlink/ViewModels/`)

- `Mail` navigation area (⌘5), unread badge on the sidebar item.
- Three panes: folder sidebar / message table (search, delivery badges) /
  reading pane (attachment save, reply/reply-all/forward with quoting).
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

## Known limitations / future work

- B1F-only gateways are refused (clean error) rather than spoken to.
- No P2P (client-to-client) sessions yet; RMS/CMS only.
- Pacing: bulk B2F sends ride the normal session queue; §4.3 token-bucket
  enforcement is a codebase-wide gap (spec §16 checklist).
- The stations list uses CMS-reported grid squares; RF-evidence-based
  gateway ranking (link-quality metrics) would be a natural AXTerm twist.
