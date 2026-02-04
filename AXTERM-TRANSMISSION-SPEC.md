# transmitting.md — AXTerm Transmission Logic (state-of-the-art, compatible)
Status: 2/2 items complete

> **Scope:** This document guides AI coders implementing **packet transmission** features in **AXTerm** (macOS, Swift/SwiftUI) **above Direwolf** via **KISS**. AXTerm already decodes/sniffs RX frames; this adds a modern TX pipeline, unnumbered (UI) app protocols, and **AX.25 connected-mode** session support (implemented in-app, transmitted via Direwolf).  
> **Compatibility rule:** Everything must remain usable on existing packet networks. Unknown frames should be ignorable by legacy stations. No “requires everyone to upgrade” assumptions.

---

## 0) References (normative + practical)

- **KISS framing** (FEND/FESC escaping, command bytes, etc.): see KISS protocol overview. citeturn0search7
- **Direwolf KISS-over-TCP** (default TCP port used by tooling, KISS utilities and assumptions): citeturn6search14
- **AX.25 concepts** (connected mode, I/S/U frames, sequence numbers, timers): driver design notes & historical AX.25 docs are widely mirrored; use the official AX.25 v2.2 spec in implementation notes where available. citeturn6search15
- **FX.25 / FEC**: implementation is below AXTerm (Direwolf/PHY). Still consider “application-level” resilience patterns. citeturn0search1 citeturn6search16

> **Important boundary:** Direwolf handles modulation/AFSK/FSK, PTT, TXDelay, persistence CSMA timing, and (optionally) some lower-layer behaviors. AXTerm’s job is: **frame construction**, **queuing/scheduling**, **session logic**, **retries**, **pacing**, **app-level reliability**, and **UX**.

- IMPORTANT: AXDP MUST remain backwards/forwards compatible by design.
  - Transport compatibility: AXDP is only an application payload carried inside standard AX.25 UI or connected I-frames. It must not require changes to AX.25, FX.25, Direwolf, or other PHY/MAC layers.
  - Wire compatibility: AXDP changes must be additive whenever possible.
    - Unknown TLVs MUST be safely skipped.
    - Receivers MUST ignore features they don’t understand and fall back to base behavior.
    - New capabilities MUST be negotiated opportunistically (PING/PONG) and MUST NOT block sending.
  - Version compatibility: AXTerm MUST support decoding older AXDP versions it has shipped, and MUST tolerate newer versions by skipping unknown TLVs and unknown feature flags.

- IMPORTANT: AXTerm MUST be able to RECEIVE and safely process AXDP-extended packets from any peer,
  including:
  - Older AXDP versions
  - Newer AXDP versions with unknown TLVs
  - Peers using AXDP over UI frames or connected-mode I-frames
  - Peers advertising capabilities or compression options AXTerm does not support

  Unknown AXDP versions or TLVs MUST NOT cause parse failure, crashes, or connection teardown.
  They MUST be safely skipped using TLV length rules, and the remainder of the message MUST be processed
  whenever possible.

- Sending may be conservative; receiving must be liberal.

- IMPORTANT: All AXDP receive logic (including version handling, TLV parsing, capability negotiation,
  compression guards, and error handling) MUST be implemented using Test-Driven Development (TDD).

  Requirements:
  - Tests MUST be written before or alongside implementation.
  - Every AXDP receive path MUST have explicit tests covering:
    - Backward compatibility (older AXDP versions)
    - Forward compatibility (unknown/newer versions and unknown TLVs)
    - Mixed peers (AXDP over UI frames and connected-mode I-frames)
    - Malformed but length-valid TLVs
    - Invalid length fields, CRC failures, and decompression guardrails
  - Unknown TLVs and unsupported features MUST be verified by tests to be safely skipped
    without breaking parsing of the remaining payload.
  - No AXDP receive feature is considered complete unless its tests pass and remain enabled
    in CI.

  Rationale:
  - AXDP is explicitly designed to evolve.
  - TDD is required to prevent silent regressions, compatibility breakage,
    and protocol ossification over time.

---

## 1) High-level goals

### Must-haves
- **A robust TX pipeline**: queue → shape → build AX.25 frames → KISS encode → send → track outcome.
- **Modern congestion/flow control** that works without requiring network-wide changes.
- **Two transport modes**
  1) **Unconnected/UI** (“datagram”): best-effort with backwards-compatible app-layer reliability.
  2) **Connected AX.25** (“session”): SABM/UA, I-frames, RR/REJ, timers/retries, windowing.
- **HIG-quality UX**: informative, calm, non-nerdy by default, nerdy when expanded.

### Non-goals
- Replacing Direwolf, writing a modem, or implementing FX.25 at the PHY/MAC layer.
- Breaking legal norms: no hidden encryption on amateur bands, etc. (If you add crypto later, it must be explicit, opt-in, and compliant.)

---

## 2) Architectural layers (what AXTerm owns)

```
┌─────────────────────────────────────────────┐
│ AXTerm UI (Terminal, Sessions, Transfers)   │
├─────────────────────────────────────────────┤
│ TX Scheduler (pacing, fairness, priorities) │
├─────────────────────────────────────────────┤
│ Link / Session Managers                     │
│  - UI Datagram Protocols (app-level)        │
│  - AX.25 Connected Mode (L2 state machine)  │
├─────────────────────────────────────────────┤
│ AX.25 Frame Builder                         │
│  - Addressing, digipeaters, control fields  │
│  - PID selection, info payload encoding     │
├─────────────────────────────────────────────┤
│ KISS Encoder + Transport (TCP to Direwolf)  │
└─────────────────────────────────────────────┘
                         │
                         ▼
                 Direwolf (KISS TNC)
                         │
                         ▼
                 Radio / Channel / Network
```

**Core principle:** keep **policy** (when/why we send) separate from **mechanics** (how frames are formed and pushed to Direwolf).

---

## 3) KISS + Direwolf interface contract

### 3.1 KISS framing basics
KISS frames are delimited with **FEND** and require escaping (FESC sequences). Command byte selects port + command. citeturn0search7

**Implementation requirements**
- Support multiple KISS “ports” (Direwolf can expose multiple channels).
- Maintain one TCP connection per configured TNC endpoint.
- Implement **backpressure**: don’t write unlimited bytes into the socket if the OS buffer is filling.

### 3.2 Transport reliability (TCP != RF success)
TCP only means **Direwolf received bytes**, not that RF delivery happened. Your “TX success” metrics must be derived from:
- Connected-mode acks (RR/REJ) if using AX.25 L2
- App-level ACKs for unconnected transfers
- Passive observation (you hear your own packet digipeated back, you see responses, etc.)

### 3.3 Timestamping + correlation
Every outbound frame gets a unique `txFrameId` so you can correlate:
- queue time, send time
- retries
- ack time (if any)
- link scoring updates

---

## 4) Traffic shaping: what you *can* control above Direwolf

You asked: “Do I first need maxlen/maxframe/paclen shaping?”  
Yes—**not by changing Direwolf’s modem**, but by shaping **what AXTerm emits** and **when**.

### 4.1 Terms mapping (practical)
- `paclen` (aka max information bytes per I/UI frame): **AXTerm chooses payload size** so each packet stays under target size.
- `maxframe` (window / in-flight frames): **AXTerm chooses outstanding frames**, especially in connected mode.
- `retries` / `N2`: **AXTerm chooses retransmissions** (connected mode) and app retries (UI mode).
- `frack` / `T1` / `resptime`: **AXTerm chooses timeouts** (connected mode) and ACK waiting.
- `txdelay`, `persist`, `slottime`: usually **Direwolf-level**—AXTerm can surface them in UI, but can’t enforce on-air CSMA precisely.

The above settings must be manually overridable in the settings interface, and those that we implement with adaptive capabilities must be able to have that feature turned off (forcing manual settings) and then back on if desired later.

### 4.2 Airtime-aware payload sizing (simple, effective)
For a target bitrate `R` (bits/s), and frame size `B` (bytes), approximate airtime:

```
airtime_seconds ≈ (B * 10) / R
```
(10 bits/byte ≈ 8 data + start/stop/bit-stuff overhead; it’s a rougher-but-useful estimator.)

**Policy:** default `paclen` should aim for **shorter frames** on busy / lossy links. As link quality improves, allow larger frames.

Example adaptive rule:
- Start `paclen = 128` bytes (UI payload)
- If `loss_rate > 0.2` or `ETX > 2.0`, drop to `64`
- If stable for `N=10` frames, raise to `192`, max `256` (configurable) (this stability check should be per link destination, not per session, and not global). 

Keep an EWMA of:
	•	loss_rate (based on ACKs in connected mode, or AXDP ACKs in UI-reliable mode)
	•	srtt / rto (connected mode) or “ACK RTT” (AXDP)
	•	retry_rate
	•	maybe dup_rate

The “stable for N=10 frames” check uses this link controller’s rolling window/EWMA.

2) Connected mode can temporarily clamp paclen

When a connected session starts, you can do:
	•	Initial paclen = min(linkSuggestedPaclen, userMaxPaclenForConnected)
	•	If session sees repeated REJ/timeouts, clamp harder inside the session immediately
	•	When the session ends, feed outcomes back into the link controller

So you get fast reaction during a session, but the long-term memory lives at the link level.

Exactly how I’d implement your “stable N=10” rule

Don’t literally count 10 frames globally. Do it like this:
	•	For each LinkKey, maintain:
	•	successStreak (consecutive successful deliveries without retransmit)
	•	failStreak
	•	“Success” means:
	•	connected mode: an I-frame is acknowledged without needing retransmit
	•	UI reliable: chunk acknowledged in SACK window without retransmit
	•	Then:
	•	if failStreak >= 1 or loss_rate_EWMA > 0.2 or ETX_EWMA > 2.0 → decrease paclen
	•	else if successStreak >= 10 → increase paclen (up to cap), reset successStreak to something like 5 (so it doesn’t rocket upward)

This avoids oscillation.

Edge cases you should decide now
	•	UI best-effort messages (no ACKs): don’t treat as success/failure for adaptation. Otherwise you’ll “learn” nonsense.
	•	No data yet for this LinkKey: start conservative (64 or 128) and probe upward.
	•	Different traffic classes: optionally have two paclen targets:
	•	paclenInteractive (smaller, safer)
	•	paclenBulk (adaptive, but capped)

Settings UX requirement (given what you wrote)

You’ll want, per parameter:
	•	Mode: Auto / Manual
	•	If Manual: value picker enabled
	•	If Auto: show “Current” + “Suggested” + “Reason” (e.g., “Loss 28%, ETX 2.7 → paclen 64”)


### 4.3 Pacing + fairness (critical in real networks)
Never “firehose” KISS.
Implement a scheduler with:
- **token bucket** pacing per destination (and per channel)
- **priority classes** (e.g., UI chat > file transfer > bulk sync)
- **jitter** to avoid synchronized collisions

Token bucket:
- rate `r` frames/sec or bytes/sec
- capacity `b` frames or bytes
- each TX consumes tokens = bytes or frames

### 4.4 Congestion control above L2 (AIMD window) (Dynamic K)
For connected mode and app-reliable UI mode, implement **AIMD** window control:
- Start `cwnd = 1`
- On successful RTT without retransmit: `cwnd += 1/cwnd` (≈ +1 per RTT)
- On retransmit timeout or REJ: `cwnd = max(1, cwnd/2)`

	•	K = 1 → stop-and-wait (very safe, slower).
	•	K = 2..4 → better throughput on good links.
	•	Too high K on lossy/busy RF → you just create collisions and retransmits, which makes things worse for you and everyone else.

“Dynamic K” = congestion control for packet

You already wrote the idea in §4.4: AIMD.

Dynamic K means:
	•	Start conservatively (K=1)
	•	Increase only when things are going well
	•	Cut it when you see loss/retries

A practical version:

State per link (destination+path+channel)
	•	kCurrent (Int)
	•	kMin=1
	•	kMax (user cap; default 4)
	•	successRounds and lossEvents
	•	srtt/rto (you already have)

What counts as “good” vs “bad”
	•	Good event: you advance VA (receive RR that newly acks frames) without any retransmit in that RTT window.
	•	Bad event: T1 timeout / retransmit, or REJ received, or repeated RNR stalls.

AIMD rule (simple and stable)
	•	Additive increase: when you complete an RTT “round” cleanly:
	•	every time you fully drain outstanding frames (or once per RTT), do:
	•	kCurrent = min(kCurrent + 1, kMax)
	•	OR the smoother version:
	•	keep a float cwnd, do cwnd += 1/cwnd, set kCurrent = floor(cwnd)
	•	Multiplicative decrease: on a bad event:
	•	kCurrent = max(1, kCurrent / 2) (integer halve)
	•	optionally also clamp paclen down immediately

This is simple, stable, and channel-friendly.

---

## 5) AX.25 frame builder (what you must implement)

### 5.1 Addresses and digipeaters
AX.25 address field includes:
- destination callsign + SSID
- source callsign + SSID
- optional digipeater path (`WIDE1-1`, `WIDE2-1`, local aliases, etc.)

**Rules**
- Provide a path editor with presets and a “safe default” (empty path on local, or a minimal digi path where appropriate).
- Validate call signs & SSIDs.
- Normalize case for display; encode per AX.25 rules (shifted ASCII in address field).
1) Use routes data to power Suggestions

In the path editor:
	•	Show a Suggested section (top) populated from your routes/ETX/ETT/decay scoring.
	•	Show Recent (last-used paths to this dest).
	•	Show Manual (custom entry).

Each suggestion should include a short reason:
	•	“Best ETT (1.8s), 2 hops, fresh 92%”
	•	“Most reliable (ETX 1.3), 3 hops”
	•	“Shortest (1 hop), moderate reliability”

2) Offer a per-destination Path Mode

Per destination (and per channel):
	•	Manual: user locks the path.
	•	Suggested: you prefill the editor with the current best suggestion, but user can edit before sending.
	•	Auto (optional / advanced): you pick the best path at send-time and can fail over.

Default should be Suggested, not Auto.

3) “Auto” behavior, if you implement it

Auto should be conservative and predictable:

Auto selection rule (per send)
Pick the path with minimum:

score = ETT + hopPenalty + congestionPenalty + stalePenalty

But with guardrails:
	•	Never exceed maxHops (default 2–3).
	•	Prefer “direct” (empty path) if you’ve heard the dest directly recently.
	•	Don’t auto-use a route if its freshness/decay is below a threshold.

Failover rule
If no response after N tries (or session connect fails), try the next-best path once, then stop and surface the choice to the user (“Tried path A, then B. Pick one.”). Don’t keep cycling paths endlessly.


### 5.2 Control types you need
You need the ability to build:
- **U frames**: SABM/SABME, UA, DISC, DM, FRMR (connected mode)
- **S frames**: RR, RNR, REJ (and SREJ but only use these if the destination node supports them - otherwise fall back)
- **I frames**: data-bearing connected frames with `N(S)` and `N(R)`

And for unconnected:
- **UI frames** with PID + payload.

### 5.3 PID selection
For your own app protocol, use a PID that legacy nodes will ignore or treat as “no layer 3”. Commonly:
- PID `0xF0` (no layer 3 / text) for human-readable messages
- Or a dedicated PID value used by your app (still must be safe on existing networks)

**Practical approach**
- Use `0xF0` for chat/terminal text
- Use an app PID or `0xF0` with a recognizable prefix for binary TLV (see below), so non-aware tools can still show something safe like `AXT1 …`

---

## 6) Unconnected (UI) “AXTerm Datagram Protocol” (AXDP)

### 6.1 Why this exists
UI frames have no built-in ack/retransmit. But we can add **optional app reliability** while remaining compatible.

### 6.2 Message envelope (TLV, versioned)
All AXDP payloads start with a short ASCII magic + version:
```
b"AXT1"
```
Then a TLV stream:
- `type: UInt8`
- `len: UInt16 (big endian)`
- `value: [UInt8]`

Core TLVs:
- `0x01` MessageType (UInt8): CHAT=1, FILE_META=2, FILE_CHUNK=3, ACK=4, NACK=5, PING=6, PONG=7
- `0x02` SessionId (UInt32)
- `0x03` MessageId (UInt32)  // per-session monotonically increasing
- `0x04` ChunkIndex (UInt32)
- `0x05` TotalChunks (UInt32)
- `0x06` Payload (bytes)
- `0x07` PayloadCRC32 (UInt32)  // integrity
- `0x08` SACKBitmap (bytes)     // selective ack bitmap
- `0x09` Metadata (UTF-8 JSON or CBOR)

**Compatibility:** if a legacy node displays it, it starts with `AXT1` then some printable bytes.

### 6.3 Fragmentation strategy (UI mode)
Given target `paclen`, compute max payload per UI frame:

```
max_payload = paclen - overhead_bytes
```
Overhead includes: magic+ver, TLVs for type/session/msg/chunk/crc.

**Default**: chunk size 64–192 bytes depending on link quality.

### 6.4 App-level ACKs (selective, efficient)
For bulk transfers over UI:
- Receiver sends periodic **SACK** acknowledgments:
  - A base `ack_upto` (highest contiguous chunk received)
  - A bitmap for the next `k` chunks indicating received/missing

This avoids one-ack-per-chunk.

**Retry policy**
- Sender maintains a set of missing chunks
- Retransmit missing chunks with exponential backoff + jitter
- Stop after `N` attempts, mark transfer failed, show actionable UX

### 6.5 ETT / pacing for UI transfers
If you already compute ETX/ETT for routes, use that:
- Choose lower `paclen` for higher ETT
- Increase ACK interval when ETT is high (avoid ack storms)
- Prefer connected mode when you can establish it

6.x AXDP Negotiation, Capability Discovery, and Compression (UI + Connected)

6.x.1 AXDP as an “application layer” over UI and Connected sessions

AXDP is not tied to UI frames. It’s an application payload format that can be carried in:
	•	Unconnected UI frames (AX.25 UI): UI + PID + AXDP payload
	•	Connected-mode I-frames (AX.25 connected): I-frame + PID + AXDP payload

Policy
	•	Use the exact same AXDP envelope/TLVs in both modes so your decoder, logging, and tooling stay unified.
	•	The transport differs (UI best-effort vs connected reliable), but the payload format does not.

Compatibility
	•	Legacy stations that just “show text” should see something safe and identifiable.
	•	AXTerm should detect AXDP by its header and treat it as structured content.

⸻

6.x.2 AXDP version marker and how it appears in the UI

Header
	•	Prefer ASCII header that prints in legacy monitors:
	•	b"AXT1" (4 bytes) as the prefix
	•	This prints cleanly. Avoid a raw 0x01 version byte if you care about human display.

UI display requirement
	•	When a received frame is AXDP:
	•	Show it as “AXDP v1” (or “AXT1”) in the transcript/bubble header or message metadata
	•	Provide a disclosure triangle / inspector with:
	•	decoded TLVs (type, sessionId, messageId, chunk stats, CRC, compression)
	•	“raw bytes” view for debugging
	•	When not AXDP:
	•	treat as plain text (PID 0xF0) or generic binary (other PIDs)

⸻

6.x.3 Capability discovery / negotiation (PING/PONG)

AXDP negotiation is opportunistic. You don’t block sending; you learn what the peer supports and upgrade when possible.

New TLVs (recommended)
Reserve extension ranges and keep your core TLVs 0x01–0x09 frozen.

Add:
	•	0x20 Capabilities (bytes; sub-TLV stream)
	•	0x21 AckedMessageId (UInt32) (optional if you reuse messageId for correlation)

Capabilities sub-TLVs (inside 0x20)
	•	0x01 ProtoMin (UInt8) — minimum AXDP version supported
	•	0x02 ProtoMax (UInt8) — maximum AXDP version supported
	•	0x03 FeaturesBitset (UInt32) — feature flags (compression, SACK, resume, etc.)
	•	0x04 CompressionAlgos (bytes list of UInt8 ids)
	•	0x05 MaxDecompressedLen (UInt32) — anti-zip-bomb guardrail
	•	0x06 MaxChunkLen (UInt16) — peer’s preferred max chunk payload

Handshake flow
	•	Sender emits a PING (MessageType=PING) with Capabilities.
	•	Receiver replies with PONG including:
	•	its own Capabilities
	•	and optionally a selected configuration (e.g., chosen compression algo)

Caching
Maintain a per-peer cache keyed by:
	•	(destination callsign+ssid, path signature, transport kind) where transport kind is:
	•	UI datagram (unconnected)
	•	connected session (per-session)

Cache fields:
	•	lastSeen timestamp
	•	protoMin/protoMax
	•	features bitset
	•	compression algorithms supported
	•	selected compression (if any)
	•	preferred chunk size
	•	maxDecompressedLen

When to negotiate
	•	On first contact with a peer (no cache)
	•	When cache is stale (e.g., >24h)
	•	When a transfer starts and you want compression or SACK but don’t know peer support
	•	When peer sends a protocol error / unknown header (downgrade)

Downgrade behavior
	•	If peer does not respond to PING:
	•	treat as “no AXDP extensions” and proceed with base behavior (no compression, simplest ACK mode)
	•	If peer responds but only supports a lower proto max:
	•	send that lower version next time
	•	If peer sends invalid caps:
	•	ignore caps and continue base

⸻

6.x.4 Compression (AXTerm-to-AXTerm only, negotiated)

Compression is only used when:
	•	Peer support is confirmed via capabilities
	•	You are sending a payload type that benefits (file chunks, some structured payloads)
	•	You do not exceed CPU/latency budgets (interactive chat should default to none)

Compression algorithm IDs (examples)
	•	0 = none
	•	1 = lz4 (fast, good default)
	•	2 = zstd (better ratio, more CPU)
	•	3 = deflate

New TLVs (compression block)
	•	0x30 Compression (UInt8) — algorithm ID
	•	0x31 OriginalLength (UInt32) — size of payload before compression
	•	0x32 PayloadCompressed (bytes) — compressed payload

MaxDecompressedLen (mandatory safety limit)

Purpose: Prevent decompression bombs, memory exhaustion, and pathological payloads.
	•	MaxDecompressedLen defines the maximum allowed decompressed size per chunk.
	•	It applies only when compression is in use.

Defaults
	•	If negotiated via capabilities:
→ use the minimum of local and peer-advertised values
	•	If not negotiated:
→ 4096 bytes per chunk
	•	Absolute hard cap (even if negotiated):
→ 8192 bytes per chunk (MUST NOT be exceeded)

Rules
	•	If 0x32 PayloadCompressed exists:
	•	0x06 Payload MUST NOT be present
	•	0x30 Compression MUST be present and MUST ≠ 0
	•	0x31 OriginalLength MUST be present
	•	CRC (0x07 PayloadCRC32) MUST be computed over the decompressed/original payload, per chunk
(verifies content integrity, not compressed bytes)
	•	Decompression MUST be guarded:
	•	Reject if OriginalLength > MaxDecompressedLen
	•	Reject if decompression output length ≠ OriginalLength
	•	Reject if CRC fails
	•	Receiver behavior:
	•	Uses CRC32 per chunk to decide retransmission
	•	Verifies FILE_META.FileSHA256 once at end of transfer before marking Complete
	•	FILE_META MUST include FileSHA256 of the entire original file bytes
(computed before chunking and compression)

Chunk sizing interaction
	•	Chunk boundaries are chosen on the original payload stream
	•	Sender MUST ensure compressed output fits under the paclen shaping target
	•	If compressed output exceeds paclen:
	•	Shrink the chunk or
	•	Fall back to uncompressed for that chunk
	•	Compression that increases size MUST NOT be used for that chunk

What gets compressed
	•	FILE_CHUNK: yes (default on if negotiated)
	•	FILE_META: usually no (tiny; wasteful). Put SHA-256 in FILE_META
	•	CHAT: no by default (latency + tiny payload); allow manual override

Connected vs UI differences
	•	Connected mode already provides ACK/retry; compression primarily reduces airtime
	•	UI mode with app reliability benefits even more (fewer retries due to reduced airtime), but MaxDecompressedLen MUST remain strict
	•	In connected mode, if your I-frame payload is already protected by link retransmit, compression only reduces airtime; it doesn’t change reliability.
	•	In UI mode, compression reduces airtime and reduces collision probability, which improves effective reliability.

⸻

6.x.5 Transfer metrics extension (completion ACK)

Purpose
	•	Provide receiver-measured data-phase and processing metrics to the sender
	•	Avoid wall-clock timestamp dependencies (durations only)
	•	Keep wire format additive and safely ignorable by older peers

New TLV
	•	0x40 TransferMetrics (bytes; versioned)
	•	Currently attached only to the transfer completion ACK (MessageType=ACK, MessageId=0xFFFFFFFF)

TransferMetrics v1 payload (little payload, fixed order)
	•	version: UInt8 (must be 1)
	•	dataDurationMs: UInt32 (receiver-measured duration from first valid chunk to last valid chunk)
	•	processingDurationMs: UInt32 (receiver-side reassembly/decompress/hash/save time)
	•	bytesReceived: UInt32 (total bytes received over the air, i.e., compressed bytes if used)
	•	decompressedBytes: UInt32? (optional; present if decompressed size is known)

Checklist
- [x] Encode TransferMetrics TLV on completion ACK (AXDP extensions only).
  - Implementation notes: `AXTerm/Transmission/SessionCoordinator.swift` builds AXDP.AXDPTransferMetrics and includes it in completion ACK when `axdpExtensionsEnabled` is true.
- [x] Decode TransferMetrics TLV and display receiver-measured stats on sender side.
  - Implementation notes: `AXTerm/Transmission/AXDP.swift` decodes TLV 0x40; `AXTerm/Transmission/SessionCoordinator.swift` stores it on the transfer; `AXTerm/BulkTransferView.swift` displays receiver data rate/duration/processing.

⸻

6.x.6 UX requirements for AXDP negotiation + compression

In the transcript/terminal:
	•	Show a small “badge” for AXDP:
	•	AXDP (and version: v1)
	•	When compression is used:
	•	show “Compressed (LZ4)” in inspector, not as noisy inline text
	•	Provide a peer capability inspector:
	•	“Peer supports: AXDP v1, SACK, Resume, Compression: LZ4/Zstd”
	•	“Selected: LZ4, Max decompressed: 5 KiB, Preferred chunk: 128B”

In settings:
	•	Toggles:
	•	“Enable AXDP extensions” (on/off)
	•	“Auto-negotiate capabilities” (on/off)
	•	“Enable compression (AXTerm peers only)” (on/off)
	•	“Compression algorithm: Auto / LZ4 / Zstd / None”
	•	“Max decompressed payload” (default conservative, 4-8 KiB)
	•	Debug:
	•	“Show AXDP decode details in transcript” (developer option)
        *.      allow setting which axdp version is enabled once we start updatingg it. Put the hooks in for that now. But default to the latest version.

⸻

6.x.7 Implementation notes (important correctness points)
	•	AXDP parser must be strict about lengths (no overruns, no negative lengths).
	•	Unknown TLVs must be safely skipped.
	•	Nested TLVs (Capabilities sub-TLVs) must also be length-checked.
	•	Capability negotiation must never block sending; it should only upgrade behavior.
	•	Keep wire format stable; version bumps must be additive whenever possible.

---

## 7) Connected mode (AX.25 L2 sessions) — what “state of the art” looks like

### 7.1 Session state machine (minimal viable)
States:
- `DISCONNECTED`
- `CONNECTING` (sent SABM/E, waiting UA)
- `CONNECTED`
- `DISCONNECTING` (sent DISC, waiting UA)
- `ERROR`

Events:
- Local connect request
- Receive UA/DM/FRMR
- Receive I/S frames
- Timer T1 expiration
- Idle timer T3 expiration

### 7.2 Sequence numbers + window
AX.25 uses `N(S)` (send seq) and `N(R)` (recv expected) mod 8 or 128 depending on extended mode.
Implement both, default to **mod 8** unless you detect/choose extended.

Window `K` (like maxframe):
- Start at `K=1`
- Allow config up to `K=4` by default, higher only if link is good

**Modern add-on:** dynamic `K` via AIMD (Section 4.4).

### 7.3 Timers: compute RTO from measured RTT
Classic AX.25 uses static `FRACK`. Modern approach: **adaptive RTO**.

Maintain:
- `SRTT` (smoothed RTT)
- `RTTVAR` (RTT variance)

Update on each acked frame (Jacobson/Karels-style):
```
RTTVAR = (1 - β) * RTTVAR + β * |SRTT - RTT_sample|
SRTT   = (1 - α) * SRTT   + α * RTT_sample
RTO    = SRTT + 4 * RTTVAR
```
Typical: `α=1/8`, `β=1/4`

Clamp:
- `RTO_min = 1.0s`
- `RTO_max = 30.0s` (or user-configurable)

Use `RTO` as your T1 timeout for retransmission.

### 7.4 Retries (N2) and link-down detection
- Default `N2 = 10` (configurable)
- On consecutive failures:
  - reduce window
  - reduce paclen
  - consider alternate path (if you support path selection)
- If `N2` exceeded → disconnect, show “No response” with details.

### 7.5 Receive logic (I frames)
On receiving an I-frame with seq `ns`:
- If `ns == VR` (expected):
  - accept payload
  - `VR = (VR + 1) mod M`
  - send RR (or piggyback in outgoing I frames)
- Else:
  - send REJ (or SREJ if negotiated) to request retransmit

### 7.6 Send logic (I frames)
Maintain send buffer for unacked frames:
- `VS` next sequence to send
- `VA` oldest unacked
- Send while `(VS - VA) < K` and queue not empty
- Start T1 if not running
- On RR with `nr`:
  - ack frames up to `nr-1`
  - advance `VA`
  - stop T1 if `VA == VS`

### 7.7 UI/UX for connected mode
- Show connection state as a compact pill: **Connected / Connecting / No response**
- Provide an inspector revealing:
  - window, paclen, RTO, retries, RTT, ETX/ETT estimates
- In the terminal transcript, visually group retransmissions and mark them subtly (don’t spam the user).

### 7.8 Session config fixed at connection start; multi-connection stabilization
- **No mid-transmission changes:** Session parameters (window K, RTO min/max, N2, etc.) are chosen once when the session is created and MUST NOT be changed for the lifetime of that session. Changing parameters during an active transfer would risk corrupting in-flight data and sequence state.
- **Multiple simultaneous connections to the same destination:** When more than one session exists to the same peer (e.g. direct and via digi), do not flip between per-route learned params. Use a **conservative merged config**: min(window), max(RTO min), max(RTO max), max(N2) across all relevant learned/config sources for that destination. This gives a stable middle ground and avoids chaotic parameter switching or corrupting any of the connections.

---

## 8) “Modern networking ideas” that *do* fit amateur packet constraints

### 8.1 Path selection using your route metrics
Given candidate paths `p`, pick the one minimizing expected delivery time:
```
score(p) = ETT(p) + λ * congestion(p) + μ * hop_penalty(p)
```
Where:
- `ETT(p)` you already compute from ETX and bitrate estimate
- `congestion(p)` can be inferred from recent retry rates or channel occupancy proxies
- hop penalty discourages long, fragile paths

### 8.2 Opportunistic rate limiting per peer
Track per-peer rolling stats (EWMA):
- `success_rate`
- `mean_RTT`
- `retry_rate`
- `dup_rate`

Then adjust:
- `paclen`
- `K`
- pacing rate
- ack interval

### 8.3 “Good citizen” bulk transfer mode
When file transfer is active:
- cap bulk bandwidth to, say, **20–40%** of your allowed tokens
- always allow interactive chat/control frames to preempt

### 8.4 Store-and-forward friendliness
For BBS/NETROM-style environments:
- prefer short messages
- allow resuming transfers
- avoid huge continuous bursts

---

## 9) File transfer designs (UI mode + connected mode)

### 9.1 Two modes, one UX
UX should present a single “Send File…” flow.
Implementation chooses:
- **Connected mode** if session is established (best)
- Otherwise **AXDP UI reliable transfer**

### 9.2 File metadata
`FILE_META` contains:
- filename (sanitized)
- byte length
- `sha256` (or at least CRC32 + length)
- chunk size
- optional description

### 9.3 Resume support
Receiver can send:
- `NACK` with a SACK bitmap for missing chunks
- Or `ACK` with “have up to N, plus these bits”

Sender can restart from missing set.

### 9.3.1 Manifest + end verification + selective retransmit (recommended)
**Goal:** Cover lost chunks, corrupt chunks (bad checksum), and collisions without blind retransmit.

**At start (manifest):**
- `FILE_META` already provides: filename, length, whole-file SHA256, chunk size, total chunks.
- Optional: per-chunk checksums in a manifest TLV (or send `PayloadCRC32` on each `FILE_CHUNK` per 6.x.4).
- Receiver then knows exactly what set of chunks to expect (indices `0..totalChunks-1`).

**Per chunk (integrity):**
- Sender: include TLV `0x07 PayloadCRC32` on each `FILE_CHUNK` (CRC32 of payload; spec 6.x.4).
- Receiver: verify CRC on each chunk; treat bad CRC as "missing" for retransmit (do not count as received).

**At end (ask recipient):**
- Sender: after sending all chunks, enter "awaiting completion" and periodically send **completion request** (ACK with messageId=0xFFFFFFFE). Receiver responds with completion ACK (all good) or NACK with SACK bitmap (missing/corrupt chunks).
- Receiver: on completion request, when `receivedChunks.count >= expectedChunks` **and** all CRCs pass:
  - Reassemble, verify whole-file SHA256, save, send **completion ACK**.
- Receiver: when still missing chunks or has bad CRCs:
  - Send **NACK** with SACK bitmap (what we have) so sender can **selectively retransmit** only missing chunks.

**Selective retransmit:**
- Sender: on NACK with SACK bitmap, decode bitmap, compute missing chunk indices, retransmit only those chunks (with PayloadCRC32). Next completion request will prompt receiver to confirm again.
- Avoids wasting airtime retransmitting chunks the receiver already has.

**Implementation status:**
- Implemented: FILE_META, whole-file SHA256 at end, per-chunk PayloadCRC32 on send/verify, completion request (ACK 0xFFFFFFFE), receiver response with completion ACK or NACK+SACK bitmap, sender selective retransmit from NACK, completion ACK/NACK for success/failure.

### 9.4 Connected mode transfer framing
Even in connected mode, keep your **AXDP TLV envelope**:
- It simplifies decoding and future extension
- It allows uniform logging + tooling

---

## 10) Implementation plan (1–10) — build in this order

1. **TX queue + persistence model**  
   - `OutboundFrame` entity (id, dest, path, payload, priority, createdAt, status)
2. **KISS TX transport** (TCP write, escaping, port selection, reconnect) citeturn6search14
3. **AX.25 frame builder** (UI first)  
   - address encoding, digis, control/PID, info field
4. **Scheduler + pacing** (token bucket + priorities + jitter)
5. **Terminal TX UI** (compose box, send, queue view, per-frame status)
6. **AXDP envelope + chat** (UI datagrams)  
   - TLV parser/encoder, message IDs, dedupe cache
7. **AXDP reliability** (ACK/NACK, SACK bitmaps, retries, resume)
8. **Connected-mode session manager** (SABM/UA/DISC, I/S frames, timers, window)
9. **Adaptive tuning** (RTO from RTT, AIMD cwnd, paclen adaptation, per-peer stats)
10. **Bulk transfer UX** (Send file flow, progress, pause/resume, failure explanations)

---

## 11) Swift implementation notes (practical code skeletons)

### 11.1 Core types
```swift
enum TxPriority: Int { case interactive = 100, normal = 50, bulk = 10 }

struct Ax25Address {
    var callsign: String  // "K0EPI"
    var ssid: UInt8       // 0...15
}

struct DigiPath {
    var digis: [Ax25Address]  // include "WIDE1-1" style if desired
}

struct OutboundFrame {
    let id: UUID
    let channel: UInt8
    let destination: Ax25Address
    let source: Ax25Address
    let path: DigiPath
    let builtAt: Date
    let payload: Data
    let priority: TxPriority
    var attempts: Int
}
```

### 11.2 Token bucket
```swift
final class TokenBucket {
    private var tokens: Double
    private let ratePerSec: Double
    private let capacity: Double
    private var lastRefill: TimeInterval

    init(ratePerSec: Double, capacity: Double, now: TimeInterval) {
        self.ratePerSec = ratePerSec
        self.capacity = capacity
        self.tokens = capacity
        self.lastRefill = now
    }

    func allow(cost: Double, now: TimeInterval) -> Bool {
        refill(now: now)
        if tokens >= cost {
            tokens -= cost
            return true
        }
        return false
    }

    private func refill(now: TimeInterval) {
        let dt = max(0, now - lastRefill)
        tokens = min(capacity, tokens + dt * ratePerSec)
        lastRefill = now
    }
}
```

### 11.3 Adaptive RTO
```swift
struct RttEstimator {
    var srtt: Double? = nil
    var rttvar: Double = 0.0
    let alpha = 1.0 / 8.0
    let beta  = 1.0 / 4.0

    mutating func update(sample: Double) {
        if let s = srtt {
            rttvar = (1 - beta) * rttvar + beta * abs(s - sample)
            srtt   = (1 - alpha) * s + alpha * sample
        } else {
            srtt = sample
            rttvar = sample / 2
        }
    }

    func rto(min: Double = 1.0, max: Double = 30.0) -> Double {
        guard let s = srtt else { return 3.0 }
        return Swift.max(min, Swift.min(max, s + 4 * rttvar))
    }
}
```

---

## 12) HIG-focused UX requirements

- **Primary UI:** a Transmission Terminal view that feels like Messages/Terminal hybrid:
  - transcript with clear sender/receiver, time, and state
  - composer with attachments and send controls
  - status indicators that don’t scream (“Retrying…”, “Queued”, “Sent”, “No response”)
- **Progressive disclosure:** default view simple; advanced stats in an Inspector sidebar
- **Accessibility:**
  - VoiceOver labels for statuses
  - Reduce Motion compatibility
  - color is never the only status indicator
- **Error copy:** actionable. Example:
  - “No response after 10 tries (RTO 4.2s). Try a shorter path or lower packet size.”

---

## 13) Testing strategy (do not skip)

- Unit tests:
  - KISS escaping round-trip
  - AX.25 address encoding/decoding
  - AXDP TLV parsing + fuzz tests
  - Connected-mode state transitions
- Integration:
  - “Loopback” mode with Direwolf + a local virtual KISS peer
  - Record/replay captured frames to validate session behavior
- Property tests:
  - retransmission never exceeds N2
  - windows never send more than K outstanding
  - timeouts clamp to [min,max]

---

## 14) Extension points (keep it open)

- Add optional **SREJ** support for selective retransmit (if worth it)
- Add “transfer profiles” (chat-first vs bulk-first)
- Add plugin decoders for other app PIDs (APRS, telemetry)
- Add multi-TNC routing and channel selection

---

## 15) Quick glossary (for AI coders)

- **UI frame:** unnumbered information frame (datagram)
- **I frame:** information frame in connected mode
- **RR/RNR/REJ:** supervisory frames (ack / receiver not ready / reject)
- **T1:** retransmit timer
- **T3:** idle poll timer
- **N2:** max retries
- **K:** window size (max in-flight I frames)
- **ETX/ETT:** expected transmissions / expected transmission time

## Meta: Implementation checklist behavior (do not remove content)

When implementing from this document, you MUST:
- Preserve all specification text in this file (do not delete sections you “finished”).
- Add a checklist under each relevant section using GitHub-flavored markdown checkboxes.
- Mark items as completed by changing `[ ]` to `[x]` as you implement them.
- If you change a design decision, annotate it inline with a short “Decision:” note and keep the original text (strike through if needed, but do not delete).
- Add brief “Implementation notes” bullets directly under the checklist items (1–3 bullets max per item) describing where in the codebase it was implemented.
- Add a small “Status” line at the top of the file summarizing progress: `Status: X/Y items complete`.


Reserved TLV ranges:

	•	Core TLVs: 0x01–0x1F
	•	Capabilities: 0x20–0x2F
	•	Compression: 0x30–0x3F
	•	Extensions: 0x40–0x4F
	•	Future: 0x80–0xFF experimental/private

LinkKey / PeerKey Definition:

	•	PeerKey = destCall+ssid
	•	LinkKey = (PeerKey, pathSignature, channel)

---

### Final note to implementers
If you’re ever tempted to “optimize” by sending bigger bursts faster: don’t. The most modern, best-behaved packet stations are the ones that share the channel, stay stable under loss, and give users clean explanations of what’s happening.
