# transmitting.md — AXTerm Transmission Logic (state-of-the-art, compatible)
Status: 21/22 items complete

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

Decision (2026-10-05, smoke run issue 51): the forward-loss average, which is
what backs K and paclen off, moves once per transmission a sample covers, at
0.1 per frame (a four-frame sample moves it about as far as one sample at the
old 0.3), and a link with no history starts it at no loss. Blending every
sample at 0.3 made a single resend at K 1, where a sample is one frame, read as
30% loss: B (ID-50) ran stop-and-wait at 64-byte frames while A (705) heard 129
of its 131 I-frames. The composite loss and ETX averages, which also judge the
reverse direction and gate upgrades, keep the per-sample blend.

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
	•	and only if SRTT ≤ 5 s. Clean and fast are different properties: loss says the path works, round trip says what a mistake on it costs. A 12-second link that never drops a frame still cannot afford a wider window, because every recovery on it takes a minute. The RTT test gates *upgrades only* — a slow but clean path keeps whatever it has already earned, since shrinking a working link helps nobody.
	•	Decision (2026-10-01, see §7.8.1): the 5 s is the allowance for everything except our own airtime. The round trip of the last frame in a burst includes the airtime of every frame queued ahead of it, so a session that has just earned a larger window measures a longer round trip on an unchanged path. The allowance is now `5 s + bytes in flight × 8 / 1200`, where bytes in flight is the most of our own I-frame bytes (information field plus 18 header bytes and 7 per digipeater) outstanding during the sample. With no bytes in flight it is exactly 5 s, as before. AXTerm cannot see a KISS TNC's modem rate, so 1200 bps is assumed; on a faster channel that overstates our airtime and loosens the gate by at most about 4 s (three 192-byte frames, the largest window that can still earn a rung). On the 2026-09-30 link (about 2.6 s of fixed overhead) a fixed 5 s let K=2 paclen 128 (4.4 s) climb once and then stopped K=3 paclen 192 (about 6.8 s) for no reason but its own frames. A 12 s path still never earns a rung.

This avoids oscillation.

Edge cases you should decide now
	•	UI best-effort messages (no ACKs): don’t treat as success/failure for adaptation. Otherwise you’ll “learn” nonsense.
	•	Decision (2026-10-03, smoke run issue 5): only samples about our own frames (a session's acks and retransmissions) move K and paclen. The network poll's per-radio figure is inferred from stored link statistics, re-filed every cycle and largely about other stations' links; it is an observed sample. It feeds the loss and ETX figures the operator sees, and stays out of the forward-loss average, the streaks, K and paclen. Before this, other stations' links on 145.070 read as "Our frames losing 23%" and a new route opened at K=1 paclen 64 before we had sent a frame. A route nobody has used opens at the operator's baseline and backs off on its first retransmission.
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
- The source address is the address of the radio the frame leaves on:
  `AX25SessionManager.localAddress(for:)`, which is
  `RadioProfile.resolvedCallsign(station:)`. The station callsign under
  Settings › General is the base call with no SSID, and a frame carries it
  only when a radio operates under it. Traffic tied to no radio leaves on the
  primary radio under the primary radio's address. See `Docs/MultiRadio.md`,
  "Station callsign and SSIDs".
- Normalize case for display; encode per AX.25 rules (shifted ASCII in address field).
- On receive, a frame whose addresses break those rules (bit 0 set in a callsign byte, anything but A-Z/0-9 with trailing spaces, an address field that never ends) is refused and logged, never shown as a station. See `Docs/AX25Decoding.md`.
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
Every AXDP message starts with a 6-byte header, then its TLVs:
```
b"AXT1"                     magic and version (4 bytes)
length: UInt16 (big endian) the whole message in bytes, header included
TLV …                       exactly length - 6 bytes of them
```
Each TLV:
- `type: UInt8`
- `len: UInt16 (big endian)`
- `value: [UInt8]`

The receiver reads a message by its length and nothing else. It is whole when its last byte has arrived, however the bytes were cut into frames on the way: one message per frame, several in a frame, or a node (NET/ROM, BPQ) that re-cut the stream into frames of its own. Rules:
- Bytes before a magic are not AXDP; the reassembler drops them (the terminal shows them on its own path).
- A length under 10 (the header and a MessageType TLV), or TLVs that do not fill the length exactly, mean the header cannot be trusted: drop the 4 magic bytes and look for the next magic.
- A well-formed message without a MessageType, or with a type this build does not know, is skipped whole by its length.
- Unknown TLV types inside a message are kept and ignored (forward compatibility).
- A message is at most 65,535 bytes, the most the length can say.

Decision (2026-10-03): the length was added before any release, so there is no older envelope to accept. Without it, a receiver took a message as ended at the next magic or where the frame ended, and a frame that ended on a TLV boundary inside a message looked whole; the data after it was lost until a frame happened to start with a magic. Smoke run 2026-10-03-1 found it when packing file chunks across frames.

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

Decision (2026-10-06, smoke run issue 2, operator: "plain text broadcasts, AXDP for connected AXDP proven stations"): a terminal broadcast is always plain text, whatever the AXDP setting. A UI frame reaches every station on the channel and only AXTerm reads AXDP; other software showed `AXT1` and binary instead of the message. AXDP chat is used only on a connected session, and only once the station has proven it speaks AXDP (capability confirmed); otherwise the line goes as plain text. `TerminalTxViewModel.payloadUsesAXDP` holds the rule.

A broadcast longer than the UI paclen (128 by default) is cut at paclen into several UI frames, never inside a UTF-8 character (decision 2026-10-03, smoke run issue 3). Receivers still show AXDP CHAT parts from older AXTerm builds as they arrive, as "(1/3) text", without holding parts back to join them.

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
	•	b"AXT1" (4 bytes) as the prefix, followed by the 2-byte message length (§6.2)
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
	•	Over UI frames, each frame stands alone: the sender MUST keep each AXDP message under the paclen shaping target
	•	If compressed output exceeds paclen:
	•	Shrink the chunk or
	•	Fall back to uncompressed for that chunk
	•	Compression that increases size MUST NOT be used for that chunk
	•	Over a connected session the rule above does not apply: AX.25 cuts a message into as many I-frames as it needs (AX.25 2.2 §6.7.2.1 bounds each I-field at N1, nothing more). Each message is handed to the session on its own, so a short final frame of one chunk never carries the start of the next.
	•	FILE_CHUNK data is 720 bytes, so with its 48 bytes of framing a chunk message is 768 bytes. Every rung of the paclen ladder (64, 128, 192, 256) divides 768, so every frame of a chunk is full whatever paclen does during the session (§7.8.1), and no cut lands on a TLV boundary inside the message. Framing is about 6% of the stream. A transfer's chunks never fall back to UI frames, and no AXDP UI frame exceeds 256 bytes.
	•	Decision (2026-10-03, smoke run issue 9): chunks were 128 bytes, a 174-byte message, which paclen 128 cut into a 128-byte and a 46-byte frame, so half a transfer's frames and window slots carried 46 bytes. Shrinking chunks to fit one frame would have carried less payload per byte of airtime. Packing chunks across frame boundaries was tried first and lost data: before the length header (§6.2), a frame that ended on a TLV boundary inside a message looked like a whole message to the receiver. With the length packing would be safe, but at 768-byte messages every frame is already full, so it is not done.

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

**UA and DM carry the P bit of the frame they answer** (AX.25 2.2 §6.2):
a SABM or DISC sent with P=0 is answered F=0, with P=1 F=1. That covers UA
to SABM (fresh link, link reset, SABM collision) and to DISC (on a link,
or crossing our own DISC), and DM to SABME, to DISC with no link or while
our SABM is out, and to SABM while our DISC is out.

**A DISC crossing ours** (both stations disconnect at once) is answered UA
and the link stays awaiting release until the peer's UA to our DISC, or T1
running out, ends it: AX.25 2.2 SDL, Figure C4.3, as Direwolf reads it
(`ax25_link.c`, `disc_frame`). Decision 2026-10-05 (smoke run issue 32,
operator: "make it follow the spec"). Until then AXTerm answered DM and
dropped the link at once, which also ended both sides cleanly. A DM to an I or S command is sent only when it polled
(§6.3.5), so it always carries F=1; P=0 commands with no link are ignored.
Until 2026-10-01 every UA and DM went out F=1
(`AX25SessionManager.processActions(answerFinal:)`, `handleInboundSABM`,
`handleInboundDISC`).

**A poll is answered before a disconnect the layer above asks for.** When
an I-frame with P=1 is delivered and the application ends the link at once
(Winlink hearing FQ, say), the RR F=1 goes out first and the DISC after it.
In the SDL the enquiry response belongs to handling the I-frame, and layer
3's DL-DISCONNECT request is a later event. `AX25SessionManager` defers a
`disconnect(session:)` asked for during a delivery and sends it after the
frame's answer (`flushDeferredDisconnects`). Decision 2026-10-06 (smoke run
issue 72, operator: "follow the spec"). Before that, B (ID-50) sent DISC P
and then RR(7) F.

### 7.1.1 Link setup, collisions and resets (AX.25 2.2 SDL, figures C4.2 to C4.5)
AXTerm folds the SDL's Timer Recovery state into `CONNECTED` (retry count
above zero) and calls Awaiting Connection `CONNECTING`. These transitions
follow the SDL:

- **Disconnect request while `CONNECTING`** (the operator cancels a connect
  nobody has answered): send one DISC with P = 1, stop T1, go to
  `DISCONNECTED`; no retries. Deliberate departure from Figure C4.2, which
  says "requeue request": read literally, the SABMs go on until UA or N2 and
  the radio keeps transmitting after the cancel. Direwolf (ax25_link.c,
  `dl_disconnect_request`) treats that as an erratum and does the same. If the
  peer did open its side (it heard a SABM but we missed its UA), the DISC
  goes over the path the SABM already crossed and releases it; if that DISC
  is lost, the peer's first frame to us draws a DM (Figure C4.1) and releases
  it then. Requeueing instead leaves such a peer half-open every time: the
  SABMs run out without a DISC. Operator decision 2026-10-05 (smoke run
  2026-10-03-1, 12.4: a canceled connect to KB5YZB-7 sent a DISC every 20 s,
  N2 times).
- **SABM while `CONNECTING`** (both stations called at once): answer UA with
  F = P and stay in `CONNECTING`. The link is up when our own SABM is
  answered. §6.3.1: after a SABM, frames other than UA and DM go out only
  once the link is set up "and if no outstanding SABM(E) exists".
- **SABM while `CONNECTED`**: the peer is resetting the link. Answer UA and
  zero V(S), V(A) and V(R). If frames were unacknowledged, discard the
  I-frame queue and give DL-CONNECT indication.
- **UA while `CONNECTED`**: unexpected, error C. The peer reset its link,
  usually for a stale or retransmitted SABM of ours. Establish the data link
  again (clear exception conditions, RC := 0, SABM with P = 1, stop T3,
  start T1), clear "layer 3 initiated" and go to `CONNECTING`. Layer 3 is
  told nothing yet.
- **UA while `CONNECTING`, layer 3 initiated**: DL-CONNECT confirm, the
  ordinary connect.
- **UA while `CONNECTING`, layer 3 not initiated** (the link we re-established
  ourselves): zero V(S), V(A) and V(R). If frames were unacknowledged
  (V(S) ≠ V(A)), discard the I-frame queue and give DL-CONNECT indication.
  If nothing was lost, layer 3 hears nothing. If the re-establishment fails
  (N2, or DM), layer 3 hears that the link went down.

DL-CONNECT indication on a link that layer 3 believed was up reaches the
layer above as the old link ending and a new one beginning (`connected` to
`disconnected` to `connected`), so a transfer riding it fails instead of
continuing with a hole in its stream. Only the station that lost frames
gives the indication: the SDL says nothing to a station that lost nothing,
so for a while one side can be on a new link while the other carries on.
Both sides' sequence numbers stay consistent throughout.

The field case for these rules is in Docs/LiveRFTest-2026-09-30.md, bug 39:
Warbler held a SABM 3.6 s before keying, T1 sent a second one, the peer
reset for it, and AXTerm used to ignore the second UA.

**A link is a pair of addresses.** A station that answers on more than one
address (its callsign and its node alias, or a mailbox SSID) can hold one link
per peer here, because sessions are keyed by the peer. A frame from that peer
to another of our addresses is for a link we do not hold, so it gets the
disconnected state's answer: DM, from the address it was sent to, for a SABM,
a DISC, or a command with P set, and nothing for anything else. It never
reaches the link on our other address
(`AX25SessionManager.answerForUnheldLink`). Before 2026-10-06 it did: with a
link up K0EPI-2 to EPINDB, B (ID-50) answered A's SABM to K0EPI-3 with UA from
EPINDB, A took that as an unexpected UA and established its EPINDB link again,
and each retry repeated it (smoke run 2026-10-03-1, issue 89).

**An abandoned connect stays abandoned.** A session given up while its XID is
out (`forceDisconnect`) drops the negotiation, so the answer arriving later
sends no SABM. Callers waiting on a connect treat a session that reads
disconnected while its XID is out as still connecting (`isNegotiating`,
`AX25ConnectProgress`); the Auto ladder used to fail its direct rung 2 s in
for that, while the link went on to come up behind it (issue 88).

### 7.2 Sequence numbers + window
AX.25 uses `N(S)` (send seq) and `N(R)` (recv expected) mod 8 or 128 depending on extended mode.
Implement both, default to **mod 8** unless you detect/choose extended.

Window `K` (like maxframe):
- Start at `K=1`
- Allow config up to `K=4` by default, higher only if link is good

**Modern add-on:** dynamic `K` via AIMD (Section 4.4).

### 7.3 Timers: T1 exactly as AX.25 2.2 defines it

T1 follows the AX.25 2.2 SDL, Appendix C, Figure C4.7b "Select T1" (2017
revision), with nothing added. Decision (2026-10-05, smoke run issue 34,
operator: "do it exactly to spec").

Maintain two values per link:
- `SRT`, the smoothed round trip time, starting at an initial default.
- `T1V`, the time T1 runs for at its next start. Its default initial value
  is the initial value of SRT.

Every start of T1 runs it for T1V. Select T1 is called where the SDL calls
it: on the UA answering our SABM (Figure C4.2), on each SABM or DISC retry
(Figures C4.2 and C4.3), when an acknowledgment leaves nothing outstanding
with the peer not busy ("Check I Frame Acknowledged", Figure C4.7a, on RR
and I frames), and on Timer Recovery's F=1 exit (Figure C4.5b). It does:

```
if RC == 0:
    SRT ← 7·SRT/8 + T1/8 − (remaining time on T1 when last stopped)/8
        (the same as 7/8·SRT + 1/8·(time T1 had run))
    T1V ← 2·SRT
else if T1 expired:
    T1V ← RC·0.25 s + 2·SRT
```

**When T1 starts.** The SDL starts T1 as layer 2 transmits a frame. Through a
KISS TNC or a sound modem a frame leaves later: after the radio keys up and
after the frames handed over before it. So each link keeps an estimate of
when its frames will have left the radio (`AX25Session.onAirUntil`: our
key-up, then each frame's airtime at 1200 bit/s), and T1 starts then, the
way a TNC-2 times FRACK from the end of its transmission. A new I-frame
added to a transmission still going out, inside the window and before any
retry, moves T1's start to the new end. Without this, a burst of four
256-byte frames (about 7.4 s at 1200 bit/s) outlasted every T1 the spec's
rules produce: each T1 expired with frames still going out, RC never got
back to 0 with everything acknowledged, SRT never learned, and the link
failed (stress matrix, 2026-10-05). The time T1 ran, for Select T1, is
counted from that start. The estimate assumes 1200 bit/s; hearing a frame
from the peer proves our transmission has ended, so it is brought back to
that moment, and a T1 still waiting for our frames starts then. Without
that it ran ahead without bound on a faster link and T1 never started.

The proof covers only frames handed to the radio before the peer began
transmitting. A frame handed over while the peer was on the air was held by
the radio's carrier detect and goes out after it, so those frames stay in
the estimate: from the moment the peer was heard, our key-up and then their
airtime. The peer may have been transmitting for its key-up plus a full
256-byte frame before we heard it (`AX25Session.peerFrameWindow`, with our
key-up standing in for the peer's), and frames handed in that window count
as waiting, except frames the heard frame answers: its N(R) proves our
I-frames from V(A) up to it sent, and a UA proves the SABM sent, however
recently they were handed over. Erring long starts T1 a little late; erring short resends frames
that are still going out, which is what happened when every frame was
written off: A (705) handed four 256-byte frames to the modem while B's four
RRs were arriving, each RR pulled the estimate back to "now", T1 expired
during A's own 7.5 s burst, and the false losses shrank its window to K 1
P 64 (smoke run 2026-10-03-1, issue 103). When the estimate moves later on a
peer frame, T1 starts again from the new end only before any retry, so it
never postpones a recovery.

A sound modem also reports when each transmission really ends
(`PacketEngine.onTransmissionEnded`, from the modem's sent-frame count). Every
link that handed that radio frames since its previous transmission ended had
them in this one, so they left at the report. When that is later than the
estimate, the estimate moves to it and T1 starts again from there
(`AX25SessionManager.transmissionEnded(on:)`). The report never moves the
start earlier, and a transmission that carried none of a link's frames leaves
its T1 alone. The key-up time is smoothed, and keying the IC-705 through
Warbler varies by seconds: a SABM handed over at 15:21:34Z reached B (ID-50)
2.85 s later, T1 ran from the estimate, and a second SABM crossed the UA (smoke
run 2026-10-03-1, issue 83). A KISS TNC reports nothing, so its links keep the
estimate.

So a retry on a connected link keeps the same T1 (Timer Recovery's T1 expiry,
Figure C4.5c, does not call Select T1), a connect or disconnect retry adds a
quarter second per retry to twice SRT, and an acknowledgment after retries
changes nothing. There is no minimum, no maximum and no doubling. A time that
cannot be one (not positive, or not finite) is dropped. A UA completing a
re-establishment with frames outstanding sets SRT to the initial default and
T1V to 2·SRT, as Figure C4.2 does. With adaptive timing off SRT never learns;
the retry rule still applies.

The initial default (`AX25SessionTimers.initialSRT`) is the operator's T1
setting, 3 s by default (the spec's XID default for T1), multiplied by
(2·digipeaters + 1) as a TNC-2 does, since §6.7.1.1 says T1 "should be
adjusted according to the number of repeaters" and gives no formula. It is
never less than §6.7.1.1's own rule: T1 "should take at least twice the
amount of time it would take to send maximum length frame to the distant TNC
and get the proper response frame back". That round trip is our key-up time
and a full frame's airtime (paclen plus address, control, PID and FCS, at
1200 bit/s), plus the peer's key-up and a supervisory frame's airtime, with a
key-up and an airtime more per digipeater. Our key-up is measured by a sound
modem (the radio's smoothed PTT confirmation, its audio buffer and the TX
delay; Warbler has taken 3.6 s to key an IC-705) and is the TX delay setting
for a TNC; the peer's is assumed to be our TX delay setting. A sound modem
learns its key-up only when it transmits, and a session is made before its
XID goes out, so on the first connect after a launch the starting T1 left the
key-up out. Just before the first SABM after an XID, the starting SRT and T1V
are worked out again with the key-up as it then stands, for a link with no
learned T1V and no sample yet (`AX25SessionManager.refreshStartingT1`). The
XID's round trip is not a sample: Select T1 is not called for it. Nothing in
this is particular to one radio; a TNC's key-up is its TX delay setting, which
does not change. Decision 2026-10-05 (smoke run issue 59: T1 at the configured
3 s against a 4.6 s round trip through Warbler, and the SABM went out twice).
A route's T1V
learned in the last 7 days replaces the initial default: the session starts
with T1V at the learned value and SRT at half of it, where the last session's
Select T1 left off. The value is kept in the database (`learned_routes`, see
§7.8.1), so it outlives a restart. Decision (2026-10-05, smoke run issue 54):
7 days, because the round trip is mostly structure (our key-up, the peer's
turnaround, the digipeaters) and barely moves from day to day, and a start
that is off is corrected by the session's first Select T1. K, paclen and the
loss figures are kept for 30 minutes only. Until 2026-10-05 the learned value was taken as SRT, so the
first T1V came out near double it and each reconnect started higher than the
last (smoke run issue 50: 7.0 s, then 12.0 s, then 19.4 s to the same station).

Until 2026-10-05 T1 was a TCP-style RTO (SRTT + 4·RTTVAR, RFC 6298), clamped
to RTO_min and RTO_max, doubled on each retry, started at 4 s, and never
below FRACK × (2·digipeaters + 1). On the first SABM of issue 34 it fired at
4 s, under a 705 round trip, and the second SABM crossed the peer's UA.

T3, the idle poll timer, is the operator's setting (Link Layer, "Idle Poll (T3)"), 30 to 3600 s, 300 s by default (`AppSettingsStore.ax25T3IdleSeconds`, read through `AX25SessionManager.idleT3Seconds` each time T3 starts). AX.25 2.2 §6.7.1.3: "The period of T3 is locally defined, and depends greatly on Layer 1 operation. T3 should be greater than T1; it may be very large on channels of high integrity." Linux, Direwolf and the Kenwood D710A use 300 s. Each time T3 starts, its period is drawn at random between 75% and 100% of the setting from the system's random generator, which the OS seeds per process; tests inject the draw. A period is never shorter than the session's T1V. Decisions: 2026-10-03 (smoke run issue 6), the draw, because two stations restart T3 on the same exchange and at a fixed period their idle polls went out together and collided; p-persistence (§6.7.1.6) cannot separate two stations that key up within one slot of each other. 2026-10-05 (smoke run 12.4), the setting and the 300 s default: at the old fixed 30 s AXTerm polled DRLNOD and W0ARP-7 about every 27 s on a shared channel. The old note that peers give up on a silent link after about 20 s had no recorded source; the operator can lower T3 for a station that does.

### 7.4 Retries (N2) and link-down detection
- Default `N2 = 10` (configurable)
- On consecutive failures:
  - reduce window
  - reduce paclen
  - consider alternate path (if you support path selection)
- If `N2` exceeded → disconnect, show “No response” with details.
- **A gap the peer never fills ends at N2 − 1.** After a REJ or SREJ, T1 keeps
  running to time the retransmission we asked for, and each expiry polls. The
  peer's F=1 answer resets the retry count (the SDL's exit from timer
  recovery) but does not fill the gap, so expiries spent chasing a gap, with
  nothing of ours outstanding, are counted separately and cleared when the gap
  fills. At N2 − 1 of them the last-ditch flush runs: the frames buffered past
  the gap are delivered and the chase ends. Without the count, a peer with
  nothing to resend (its V(S) started again after a link reset, and a late
  duplicate of an old frame sat out of sequence here) answered RR P with RR F
  every T1 for as long as the link lasted (full-stack fuzz, 2026-10-02).

**Quitting.** Quitting is layer 3 going away, so every live link gets a
DL-DISCONNECT: DISC, then awaiting release. The quit waits until each one
settles (the peer's UA or DM, or the DISC's first T1 running out, counted from
when the frame left the radio, §7.3) before it closes the radios, up to 12 s
in all. It does not retry the DISC to N2: a link still up after one T1 is left
for the peer to time out, as it would be anyway. Until 2026-10-06 the radios
closed 0.4 s after the DISCs were handed over. That suited a KISS TNC, which
keeps a frame it has been handed, but AXTerm's own sound modem still had the
DISC queued, and keying an IC-705 through Warbler takes seconds, so no DISC
reached the air and the peer polled a dead link until a relaunched AXTerm
answered DM (smoke run 2026-10-03-1, issue 85).

**Going to sleep (Mac).** The same DISCs and the same wait, then the radios go
down, then the machine sleeps. `SystemPowerMonitor` registers for IOKit's
system power messages, which let an app hold a sleep until it acknowledges
(macOS waits up to 30 s); the hold is capped at 15 s. NSWorkspace's sleep
notification, used before, only says a sleep is happening. Idle sleep is not
vetoed: keep-awake's power assertion already prevents it while the station is
busy.

**Leaving the screen (iPhone, iPad).** AXTerm has no background mode, so iOS
suspends it a few seconds after it goes to the background, and its links died
without a DISC. Leaving the screen now asks for background time
(`BackgroundGoodbyeController`). After a grace of up to 10 s, so a quick trip
to another app keeps the session, every live link gets its DISC and up to 12 s
to settle, with 3 s of the allowance kept in hand (`BackgroundGoodbye.plan`).
Coming back first cancels it.


#### Calls arriving on an APRS channel

A radio on an APRS channel accepts no inbound link. A SABM that arrives on it,
with no link of ours to that peer up, is answered DM from the address it was
sent to, as AX.25 2.2's disconnected state answers a station it cannot accept;
no session is created. An XID command with P set is answered DM and one
without P is ignored. A link this station opened on the radio is never
refused, so the peer's link reset still reaches it. Ping probes never leave on
such a radio, even when the operator asks. Operator ruling, 2026-10-06; see
`RadioProfile.runsPacketServices` and Docs/Settings.md.

### 7.5 Receive logic (I frames)
On receiving an I-frame with seq `ns`:
- If `ns == VR` (expected):
  - accept payload
  - `VR = (VR + 1) mod M`
  - **P=1:** answer immediately with RR F=1 — that single RR is cumulative
    and acknowledges everything delivered so far
  - **P=0:** arm T2 (if not already armed) and send nothing yet
- Else if `ns` is inside the **receive span** ahead of `VR`:
  - buffer the frame for later delivery
  - send REJ once per gap (or SREJ if negotiated); start T1 to time the
    retransmission we just asked for. REJ carries `N(R)`, so it settles any
    pending T2 ack debt.
- Else (outside the span — most likely a duplicate):
  - discard; re-advertise `VR` cumulatively (immediately with F=1 on P=1,
    otherwise via T2 like any other ack)

**The layer above hears last.** A delivered payload, and the news that an
inbound frame acknowledged some of ours, reach the terminal, a claim or AXDP
only after the frame's own actions (acks, T1, T2, T3, a REJ's retransmission)
have run. Whoever is told may send at once: YAPP's AF on EF, AXDP's completion
ack, a Winlink line, or YAPP's next blocks pumped from the claim's ack handler.
Told first, those frames were followed by the stop of T1 computed while
nothing was outstanding, so a lost one was never resent and the exchange sat
until the protocol above timed out; and a block pumped on a REJ's ack was also
picked up as a retransmission and sent twice (full-stack fuzz, 2026-10-02).
The SDL queues a layer 3 request and handles it after the transition in
progress, which is the same order.

#### T2 delayed acknowledgment

Acks are cumulative, so one RR answers a whole burst — sending one per frame
spends a key-up (~0.5 s of channel at 1200 baud) per frame and, on simplex,
risks colliding with the peer's next I-frame, converting the ack itself into
inbound loss and a go-back-N resend. Rules:

- Each in-sequence P=0 delivery **restarts T2**, so the delayed ack goes out
  once the peer's burst has paused, never in a gap partway through it. On
  2026-10-01 an arm-once T2 drew an RR 2 s into a 4 s burst; the sender
  filled the freed slot and keyed over our answer to its poll, and the
  session fell to K1 (live test log, bug 25).
- The restart is bounded: the ack goes out no later than **3 × T2** (6 s)
  after the first delivery it is owed for. Unbounded restarting was tried
  before and rejected, since arrivals faster than T2 put the ack off until the
  peer's T1 fired first (RTO oscillation in the adaptive harness). A lone
  frame is still acked one T2 after it.
- The debt is settled by whatever carries `N(R)` first: the F=1 response to a
  P=1 poll, an outgoing I-frame's piggybacked `N(R)`, a REJ, or the RR that
  T2 itself fires (F=0). A settled debt disarms T2; a stale T2 expiry with
  nothing owed stays silent.
- **T2 must sit inside every plausible peer T1.** Production default 2.0 s:
  longer than one max-size frame's airtime at 1200 baud (~1.9 s, so
  back-to-back frames batch), under the 3.0 s T1 default a peer starts
  from. Timers clamp T2 to ⅔ of the link's initial SRT (§7.3), but never
  below one frame of our N1 on the air plus a tenth
  (`AX25SessionTimers.frameGap`), and with no T2 configured the default is
  that gap when it is longer than 2 s. A clamp under one frame let T2 run
  out between the frames of a burst: a link resuming a learned T1V near
  5 s got T2 ≈ 1.67 s against 256-byte frames of 1.83 s, and the phone
  acked every frame of A (705)'s bursts separately (smoke run 2026-10-03-1,
  test 13.3). A T2 set explicitly is kept as set.
- In practice T2 rarely fires: RMS gateways end every burst with a P=1 frame
  (field capture 2026-08-24: 208 inbound I-frames, every burst
  poll-terminated), and the mandatory F=1 response carries the ack.

#### Receive span

The receive span is `M / 2` — how far ahead of `VR` an out-of-sequence I-frame
may sit and still be buffered. Inside it, a sequence number ahead of `VR` is
unambiguously a future frame; at or beyond it, the same number may be a
duplicate one lap back, and buffering it as "future" would deliver a lap-old
payload when `VR` wraps onto it.

**The span is not `K`.** `K` is the *transmit* window this station chose for
frames it sends; it says nothing about how many frames the peer keeps in
flight, and nothing negotiates a common value without XID. Deriving the span
from `K` means a station that has throttled itself to `K=2` throws away frames
a peer running four outstanding frames legitimately sent — and once `VR`
reaches them, it must ask for frames the peer already sent and considers
delivered. That deadlocks the link. Field capture 2026-08-24 (W0ARP-10):
`N(S)=7` arrived twice while `VR=4`, was discarded both times, and the session
died 60 s later still waiting for it.

The out-of-sequence buffer must be able to hold a full span; sizing it to `K`
silently re-discards frames the span test just accepted.

#### T1 during REJ recovery

While a REJ is outstanding, T1 is timing the *peer's* retransmission, not
anything this station sent. An inbound RR must therefore leave it alone — it
must be neither stopped nor restarted:

- Stopping it disarms REJ recovery. On a receive-heavy link nothing of ours is
  ever outstanding, so a peer's keepalive polls cancel T1 before it can fire
  and a single lost REJ strands the gap permanently.
- Restarting it is the same stall by another route: each poll pushes the
  deadline out, so a peer polling faster than the RTO keeps T1 alive forever
  without it ever expiring.

T1 stops on an RR only when no gap is outstanding.

#### Selective reject (SREJ)

Available only after XID negotiation (below). A receive gap draws
`SREJ(V(R))` — retransmit exactly the missing frame — instead of go-back-N
REJ. Discipline:

- One SREJ outstanding per gap; T1 times the awaited retransmission.
- The F-bit asymmetry (§4.3.2.4) is load-bearing: **SREJ F=1 acknowledges
  everything below N(R); SREJ F=0 acknowledges nothing.** Sending an F=0
  SREJ therefore must NOT settle the T2 ack debt (the cumulative RR still
  goes out), and receiving one must not clear the send buffer.
- When filling one gap exposes another (frames beyond it still buffered),
  SREJ the new missing frame immediately — waiting costs a full T1.
- Transmit side: an inbound SREJ resends only frame N(R), with N(R)
  refreshed to the current V(R). Duplicate SREJs for the same frame are
  suppressed (T1 owns the retry), same as the REJ amplification guard.

### 7.5.1 AX.25 2.2 parameter negotiation (XID)

Before the first SABM to an unknown station (per-callsign cache), send an
XID command (control 0xBF) offering: SREJ, what we can receive as N1 and k
(N1 = 256, k = 4), **modulo 8 explicitly**. N1 and k in XID are the
receiver's limits (AX.25 2.2 §4.3.3.7, §6.3.2): the peer holds the frames it
sends us to them. They are not our own K and paclen. Our decoders and receive
path take any information field up to 256 bytes, and k is the receive span
(modulo / 2), since a peer with k frames in flight has at most k - 1 of them
past a gap and the out-of-sequence buffer holds the span less one. A buffer
configured smaller (`maxReceiveBufferSize`) lowers k to match
(`AX25SessionManager.receiveN1`, `localXIDParameters`). Until 2026-10-01 the
offer carried our send ceilings, which with in-session growth off are the
start values, so 2.2 peers sent us 128-byte frames two at a time. Wire format and bit values follow the field
reference (Direwolf xid.c): FI 0x82, GI 0x80, 16-bit group length,
PI 2 / 3 / 6 / 8 / 9 / 10. A command offers a menu; a response picks one.

Outcomes, all cached per callsign so the cost is paid at most once:

- **XID response** → adopt: SREJ iff selected; PACLEN = min(ours, their
  N1); K = min(ours, their k). N1/k are notifications — ceilings, never
  raised. Then SABM.
- **FRMR** → the spec's documented pre-2.2 answer (§6.3.2): "use
  defaults". Proceed with plain SABM. Never an error.
- **DM** → what BPQ answers: it holds no link to us. Treated as FRMR.
- **Silence** → one RTO, then plain SABM. An answer can still arrive after
  that: a DM or FRMR heard before the SABM that followed has left the radio
  (the SABM's off-air time as estimated when it was handed over, §7.3) cannot
  answer the SABM, since the peer has not heard it yet. It answers the XID:
  the peer is remembered as not doing XID and the SABM keeps waiting for its
  own answer. Decision 2026-10-05 (smoke run 2026-10-03-1, test 12.4):
  DRLNOD's DM to an XID landed 0.45 s after the SABM was handed over, was
  taken as refusing it, and DRLNOD's UA then found no session; its poll drew
  a DM. A DM or FRMR after the SABM is out is still the SABM's answer.
- A malformed XID response resolves as unsupported — a peer's encoding bug
  must not strand the connect.

Inbound: an XID command draws a response selecting the intersection of the
offer and our capabilities, with the same N1 and k as our own offer; the SABM that follows opens the session with
exactly what the response promised.

**Modulo 128 is deliberately not offered.** Extended mode changes the
control-field length of every I- and S-frame, and the inbound KISS decode
pipeline is not session-aware — it cannot know where a peer's two-byte
control field ends. At 1200 baud the window is not the bottleneck anyway:
k=7 × 256 bytes keeps ~14 s of airtime in flight. SREJ and the N1/k
exchange carry all the value at deployable risk.

### 7.6 Send logic (I frames)
Maintain send buffer for unacked frames:
- `VS` next sequence to send
- `VA` oldest unacked
- Send while `(VS - VA) < K` and queue not empty
- **Checkpoint (§6.2): the frame that fills the send window carries P=1** —
  the peer's mandatory F=1 response acks the burst at once, which matters
  against receivers that batch acks on T2. Only on window-full, not on every
  burst end: some node stacks (DRLNOD, live capture) DM a session that polls
  on every idle line.
- Start T1 if not running, for T1V (§7.3). Until 2026-10-05 T1 was
  max(adaptive RTO, FRACK × (2 × digipeaters + 1)), with a delayed-ack
  formula kept behind a switch; both are gone. The spec's SRT is timed from
  T1's start to the acknowledgment that leaves nothing outstanding, so it
  already includes a peer holding its ack for its T2.
- On RR with `nr`:
  - ack frames up to `nr-1`
  - advance `VA`
  - stop T1 if `VA == VS`
- **A peer's RR or RNR poll draws RR F=1 and nothing else**, even with our
  frames outstanding and none of them acknowledged (§6.2 and the 2.2 SDL).
  The poll's `N(R)` may predate frames we sent after it, and resending those
  makes duplicates that 2.0 and Linux stations answer with REJ, which draws
  more resends. Lost frames come back through T1, or through the peer's REJ
  or SREJ once it sees a gap. Until 2026-10-01 such a poll resent the
  outstanding frames and counted the resend toward N2.
- **A peer that polls but never acks still fails the link after N2.** The
  2026-08-22 livelock (KB5YZB-7: the peer polled inside our RTO, each
  poll-driven resend restarted T1, T1 never expired, the same frame went out
  forever) cannot recur, because the poll path no longer transmits I-frames
  or touches T1: an RR that acknowledges nothing neither stops nor restarts
  T1, and a peer's command never clears the retry count (only an F=1
  response does, §6.7.1.1). T1 keeps its deadline, each expiry resends and
  counts, and N2 trips on T1 expiries alone. The poll path does not count
  toward N2: it retransmits nothing.

### 7.7 UI/UX for connected mode
- Show connection state as a compact pill: **Connected / Connecting / No response**
- Provide an inspector revealing:
  - window, paclen, RTO, retries, RTT, ETX/ETT estimates
- In the terminal transcript, visually group retransmissions and mark them subtly (don’t spam the user).

### 7.7.1 Turnaround loss hint (TX delay stays manual)

Live RF test 2026-09-30 (Docs/LiveRFTest-2026-09-30.md, finding 3): an
IC-705 keyed through Warbler kept an unmodulated carrier up about 0.7 s
after each frame. The TNC4 at the other end heard no tones, treated the
channel as clear, answered inside that window, and the 705 missed the start
of every quick reply. T1 retries, seconds later, got through. Raising the
TNC4's TX delay to 800 ms fixed it.

AXTerm never changes TX delay itself. Waiting out one station's tail would
add dead air to every exchange with every peer. It shows a hint instead,
from evidence each session already has (`TurnaroundEvidence`):

- **Samples.** This session's I-frames, first sends and resends alike,
  timed from the last frame heard from the station (stamped by the
  coordinator before the frame is handled). Handed to the modem under
  1.0 s after: a turnaround frame. 2.0 s or more after: a later frame.
  Between the two, or before anything was heard: not a sample. Only the
  first I-frame of a burst counts (frames handed over less than 0.25 s
  after another I-frame share its transmission, and go-back-N resends
  them whenever the first is lost). S-frames are not counted: whether an
  RR was heard is not observable, and nearly all of them are turnaround
  frames, so there is nothing to compare them with.
- **Outcome.** Acknowledged before any resend: heard. Sent again (T1, REJ
  or SREJ, the same marks Karn's algorithm uses): missed. A cleared send
  buffer drops frames still outstanding.
- **Window.** The last 40 resolved samples of each kind, none older than
  30 minutes. Reset when the session connects or the peer resets the link
  with SABM.
- **Shows** when there are at least 12 turnaround and 8 later samples, at
  least half the turnaround frames were missed, at most one later frame
  in five was, and a one-sided Fisher exact test puts the chance of loss
  unrelated to timing splitting them that unevenly at 1 in 2,000 or less.
  Plain loss spread over both kinds must not raise it; a late hint is
  better than a wrong one.
- **Clears** when under 35% of turnaround frames are missed, over 35% of
  later frames are, or either count falls below its minimum. The gap
  between the two thresholds keeps it from flickering.
- **Where.** A line under the connection strip naming the station heard
  last (the peer, or the first digipeater, which is also the one that must
  hear the reply) and this radio's TX delay when AXTerm's value reaches
  the TNC or modem. The tooltip gives the counts and the chance, and says
  that another station keying up as soon as the channel clears can cause
  the same pattern.
- **Logged.** A `TxLog` warning, so a Sentry breadcrumb, each time the hint
  appears or clears, with the four counts.

The rule works the same with a KISS TNC or the sound modem, since it uses
only when frames were handed over and whether they were acknowledged. A
station that mostly receives sends few I-frames and so collects little
evidence.

### 7.8 Session config fixed at connection start; multi-connection stabilization
- ~~**No mid-transmission changes:** Session parameters (window K, RTO min/max, N2, etc.) are chosen once when the session is created and MUST NOT be changed for the lifetime of that session. Changing parameters during an active transfer would risk corrupting in-flight data and sequence state.~~
  - Decision (2026-10-01, live RF test I-1, `Docs/LiveRFTest-2026-09-30.md`): RTO min/max, N2, modulo, SREJ and the ceilings on K and paclen are still chosen once when the session is created and do not change. The K and paclen a session actually uses may move during the session, below those ceilings, under the rules in §7.8.1. The concern above is about sequence state and data in flight, and §7.8.1 protects both: K never rises while a frame is outstanding, and a new paclen applies only to data cut into frames after the change. Freezing them cost too much: the 2026-09-30 session sent 61 I-frames with no retransmission and still ran 14 minutes at K=2 paclen 128 (about 315 bps on a 1200 baud channel), because the starting K was also the ceiling for the whole session.
- **Multiple simultaneous connections to the same destination:** When more than one session exists to the same peer (e.g. direct and via digi), do not flip between per-route learned params. Use a **conservative merged config**: min(window), max(RTO min), max(RTO max), max(N2) across all relevant learned/config sources for that destination. This gives a stable middle ground and avoids chaotic parameter switching or corrupting any of the connections.
  - Decision (2026-10-01): the merge also covers the values that move. While two or more sessions to the same station are open, each runs the smallest K and paclen any of them would choose, clamped to its own ceilings. When one ends, the others are free to grow again.

### 7.8.1 K and paclen during a session

**Status (2026-10-02): on by default, toward AXTerm peers only**
(`SessionCoordinator.inSessionLinkGrowth`, `growsInSession(toward:)`).

History: on the air on 2026-10-01 a session grew to K=3 with 174-byte frames,
so each burst ran about 4 s, longer than the receiver's 2 s T2. The
receiver's delayed ack went out part-way through the burst, the stations
keyed over each other, and the session fell back to K=1, paclen 64. Growth
was switched off. Three changes since:

- **The receiver holds its ack.** T2 restarts on each frame of a burst,
  within 3 × T2 (§7.5, T2 delayed acknowledgment).
- **Only toward a peer that holds its ack the same way**: one that has
  confirmed AXDP, which only AXTerm does. Any other station keeps the K and
  paclen its session started with. Our XID still advertises the ceilings
  whenever growth is on, since they say what we can receive.
- **A floor.** A growing session never runs below what it would run with
  growth off (`AX25SessionConfig.minWindowSize`, `minPaclen`, set from the
  route's learned values). Growth climbs above them and backs off down to
  them; shrinking further is left to the between-session learner, as with
  growth off. Without the floor the live session followed the learner to
  K=1, paclen 64 on lossy links (a single sample with two retransmissions
  reads as 100% loss), and growth averaged 121 bps against 271 for growth off
  in the stress harness's mode comparison.

Mode comparison with all three (`ConnectedModeStressTests.testModeComparison`,
2026-10-02), growth off against growth on: the 705 field setup 469 to 721
bps, clean 1200 baud 522 to 660, 9600 baud 1113 to 1656, via a digipeater 251
to 287; 10% loss 309 to 302, 20% loss 215 to 215, fades 350 to 342; 271 to 286
overall. The test now fails if growth falls more than 10% behind growth off
in any scenario, or behind it overall.

**Ceilings**, fixed when the session is created (`AX25SessionConfig.maxWindowSize`, `maxPaclen`):
- K: 4. Four 256-byte frames already hold a 1200 baud channel about 7.5 s per burst, so 4 is the most we allow at 1200 baud, and since AXTerm cannot see a KISS TNC's modem rate it is the most we allow at all.
- paclen: 256 on a direct path, one ladder rung less per digipeater (`TxAdaptiveSettings.paclenCeiling(forHops:)`: 192 for one, 128 for two or more).
- Both are clamped to what the peer advertised in XID (k and N1). Without an XID exchange we assume the AX.25 defaults the code already assumes, N1 = 256 and k = 4 for modulo 8 (`AX25Constants.defaultWindowSize`), which the ceilings above never exceed.
- A K or paclen the operator set by hand, adaptive transmission off, or a station reset to defaults: that parameter has no ceiling to grow toward and stays fixed for the session, as before.
- Our XID offer (and our answer to a peer's XID) advertises what we can receive, N1 = 256 and k = 4 (§7.5.1), not these ceilings or the start values. The ceilings limit what we send; advertising them would hold the peer to our own K and paclen toward us.

**Start** (`AX25SessionConfig.windowSize`, `paclen`, `startSource`), in order:
1. Another session to the same station is open: the merged config of §7.8.
2. This route's own evidence from the last 30 minutes (the per-route adaptive cache), including evidence from before a restart.
3. The values this route last confirmed, if confirmed within 24 hours (`ConfirmedLinkMemory`).
4. The radio's channel figure, then the configured defaults (K=2, paclen 128).

Only confirmed values seed a session. An upgrade still on probation counts as the values it would roll back to (`TxAdaptiveSettings.confirmedWindow`, `confirmedPaclen`). The memory is keyed by radio, station and path, so a digipeated path's figures never seed the direct path. It is written when a probation trial passes, lowered when the link backs off, and never raised by anything but another passed trial; a backoff with no record writes nothing. Clear All Learned and a per-station reset clear it.

**Across restarts** (`SQLiteLearnedRouteStore`, `LearnedRouteMemory`). Each route's and each channel's learning is written to the `learned_routes` table, one row per radio, station and path, at most once every 5 s while samples arrive and again at quit. A row holds the confirmed K and paclen, the ceilings, the loss and ETX averages, the last T1V and the clean streak, and the time of its last sample by the wall clock. At launch a row under 30 minutes old comes back as the route's adaptive entry, keeping its own time so it still expires 30 minutes after it was learned; a trial in progress at quit does not come back, only the values it would roll back to. The T1V comes back for 7 days (§7.3). Rows older than 7 days are deleted at launch. A row more than a minute in the future, from a clock set back, is used for nothing; one a moment ahead is the database rounding to milliseconds. Clear All Learned empties the table; a per-station reset deletes that station's rows, because the reset itself is not kept across a restart. Test mode starts each launch with a fresh database (Docs/TestIsolation.md), so nothing carries across a relaunch there. Decision: 2026-10-05, smoke run issue 54 (test 11.2 found nothing survived a restart).

Decision: 24 hours. It covers the sessions an operator runs to one station in a sitting (a test, a break, more tests; an evening of BBS visits) and stops short of the changes that make an old figure wrong: another radio or power level, a different antenna, band conditions, the other station's TX delay changed overnight. A start that is too high costs little, since the first retransmission halves K and steps paclen down, but there is no reason to pay it with a stale figure.

**During the session**:
- Every link-quality sample from the session runs through the route's controller (`TxAdaptiveSettings.updateFromLinkQuality`, §4.2) with the session's ceilings installed (`applyLinkCeilings`), so the route never probes a value the session could not run and a trial cannot pass without having been tried. The session then follows the controller: one rung after a clean streak (10 frames; doubled after a failed trial), on probation for 10 frames, K halved and paclen stepped down on a retransmission.
- **K rises only when nothing is outstanding.** A raise decided while frames are in flight waits (`AX25Session.pendingWindowSize`) and takes effect at the next point where new frames may go out with nothing outstanding, before the burst is measured. The sequence state therefore never counts frames sent under a K other than the one in force.
- **K falls at once.** Lowering the gate only stops new frames; the frames in flight stay counted and are acknowledged or retransmitted as before. Sequence invariants are checked against the ceiling, which never moves. The AIMD window (§4.4) is capped at the live K and follows it, so a loss always cuts below the K in use.
- **A new paclen applies only to data segmented after the change.** Data is cut into frames when it is handed to the session; frames in flight and chunks already queued keep their size, and a retransmission resends the frame as it was built.
- NET/ROM datagrams (PID 0xCF) are sized from the paclen when the circuit opens and are never split: if paclen falls afterwards, the datagram goes out whole, which is safe because it is within the ceiling the peer accepted.
- Determinism: the same sequence of samples produces the same trajectory of K and paclen.

**Observability**: each change is a breadcrumb (`Session window raised`, `Session window lowered`, `Session paclen raised`, `Session paclen lowered`) carrying the controller's reason and evidence: clean streak and what the next upgrade needs, smoothed loss both ways, SRTT, bytes in flight, frames left on trial, outstanding frames, and the ceiling. The existing warnings for a collapse to stop-and-wait and for a rolled-back upgrade are unchanged.

**UI**: during a session the status bar shows the live K and paclen, not the controller's suggestion. Its tooltip, the K and P cards in the adaptive popover, and the K in the session strip say why: the values in use, the ceilings, a raise waiting for frames in flight, where the start came from, and the last reason for a change (`AdaptiveLiveLink.explanation`).

Checklist:
- [x] Ceilings from the hop count, the K=4 cap, the operator's manual values and the peer's XID; XID offer advertises our receive capacity (N1 256, k 4)
  - Implementation notes: `AX25SessionConfig.maxWindowSize/maxPaclen`, `negotiating(with:)`; `SessionCoordinator.linkCeilings(hops:)`, `configFromAdaptive`; `AX25SessionManager.localXIDParameters`.
- [x] Start from the last confirmed values (24 h, by radio, station and path), else recent evidence, channel or defaults
  - Implementation notes: `ConfirmedLinkMemory`; `getConfigForDestination`, `learningEntry(for:)` and `applyLinkQualitySample` in `SessionCoordinator`.
- [x] Growth and backoff in the session: K up only at quiescence, K down at once, paclen only for newly segmented data, merged values across sessions to one station
  - Implementation notes: `AX25SessionManager.updateLinkTargets`, `reconcileLiveLink`, `applyPendingWindowIfQuiescent`; `AIMDWindow.setMaxWindow`; `SessionCoordinator.pushLinkTargets`.
- [x] Round-trip allowance for upgrades includes our own airtime; live values and their reasons in the status bar, popover and session strip
  - Implementation notes: `TxAdaptiveSettings.upgradeSrttAllowance(bytesInFlight:)`, `LinkQualitySample.peakBytesInFlight`; `AdaptiveLiveLink`, `AdaptiveStatusStore.updateLive`. Tests: `InSessionLinkGrowthTests.swift`.

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

### 9.3.2 Canceling a transfer (either side)

Decision: the core message types have no abort, and adding one would not be
understood by AXTerm versions already on the air. Cancel therefore reuses
the message a receiver sends to decline an offer: NACK with the transfer's
SessionId and MessageId 1.

- A receiver that cancels mid-transfer sends it to the sender. An older
  sender treats it as "declined by remote" and stops; a newer one marks the
  transfer canceled.
- A sender that cancels sends it to the receiver. An older receiver ignores
  a NACK for an inbound session, which is harmless; a newer one marks the
  transfer canceled and drops its partial state.
- Completion NACKs (MessageId 0xFFFFFFFF) are never read as a cancel.
- Nothing more of a canceled or paused transfer goes on the air than has to.
  The sender hands the link one chunk at a time; a chunk the session still
  holds queued whole, none of it numbered or sent, is dropped when the
  sender cancels, when the receiver's cancel arrives, and when the sender
  pauses (resume sends it again). A chunk already started is finished, or
  the receiver would read what follows as the rest of it. Before this, A
  (705) went on sending queued 64-byte frames for 30 s after the phone
  canceled, and through a 30 s pause (smoke run 2026-10-03-1, issue 105).

Checklist:
- [x] Cancel reaches the other station and both ends finish canceled
  - Implementation notes: `SessionCoordinator.cancelTransfer` /
    `sendAXDPCancel` (SessionCoordinator+FileTransfers.swift);
    `handleNackMessage` for the receiving side of it. Tested in
    `TwoStationTransferTests`.
- [x] Cancel from either side, and pause, drop a chunk still queued whole
  - `dropChunkQueuedWhole`. Tested in `AXDPCancelQueueTests`.

### 9.5 Transfers that cannot finish

A transfer must end with a reason, never sit "sending" forever.

- [x] A transfer riding a connected session fails when that session closes
  or times out, naming which
  - Implementation notes: `failTransfersOnLinkLoss`, wired to the session
    state callback; reasons from `TransferLinkLoss`.
- [x] A transfer with no activity for too long is failed by a watchdog, with
  a limit per kind of wait (acceptance, sending, completion, receiving)
  - Implementation notes: `TransferWatchdog`, `runTransferWatchdog`.
- [x] Offers are judged (deny list, size cap, allow list) in the
  coordinator as they arrive, whatever the UI is showing
  - Implementation notes: `TransferOfferPolicy`, `applyOfferPolicy`.

### 9.6 Legacy protocols over connected mode (YAPP)

YAPP is a third-party wire protocol and follows §16: plain PID 0xF0
I-frames, never an AXDP envelope, and the session's byte stream claimed for
the length of the transfer. The frame table is the published one (WA7MBL,
with YAPPC checksums); see `Docs/PacketFileTransfer.md`.

- [x] The protocol chosen in the Send File sheet is the one sent; a protocol
  with no sender is refused, never replaced by AXDP
  - Implementation notes: `TransferSendRoute`, `startTransfer(to:fileName:data:...)`.
- [x] YAPP send and receive over a connected session, byte-exact to the
  frame table, stream-parsed across I-frame boundaries
  - Implementation notes: `YAPPProtocol.swift`, `YAPPSessionTransfer.swift`.
- [x] A YAPP download started by a BBS is recognized only by an exact SI
  packet (ENQ 01) with no other transfer running on that session
  - Implementation notes: `YAPPReceiveDetector`, `interceptUnclaimedDelivery`,
    `AX25SessionManager.onUnclaimedDelivery`.

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
    - [x] Send file flow on Mac, iPad and iPhone (picker, multiple files, drop, Mac menu command)
    - [x] Progress, pause and resume that restarts sending, cancel that reaches the peer
    - [x] Failure explanations for declines, timeouts and lost links
    - [x] Received files saved where the operator can reach them, with Quick Look / Finder / Share
      - Implementation notes: `Docs/PacketFileTransfer.md`; `ReceivedFileStore`, `TransferUI.swift`,
        `BulkTransferView.swift`.

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

## 16) Third-party wire protocols over connected mode (Winlink B2F)

AXTerm can run **wire-exact third-party protocols** (protocols whose byte
stream is defined outside AXTerm) over an AX.25 connected session. The first
of these is the Winlink **FBB/B2F** mail exchange. Rules:

- Third-party protocol bytes are carried in I-frames with **PID `0xF0`** and
  **MUST NOT** be wrapped in an AXDP envelope — the remote end is a foreign
  implementation and the byte stream must match its specification exactly.
  (§9.4's "keep the AXDP TLV envelope" applies to AXTerm's own file
  transfers, not to foreign protocols.)
- The protocol conversation claims the session's delivered byte stream
  **exclusively** (`AX25SessionManager.claimDelivery`), so terminal
  line-splitting and AXDP magic-detection never see foreign bytes. Claims
  are released when the conversation ends.
- Session parameters remain fixed at creation (§7.8); the protocol layer
  never mutates link config mid-session.
  - Decision (2026-10-01): K and paclen may now move inside the session's
    ceilings (§7.8.1), driven only by the link controller. The protocol
    layer still never changes them, and its bytes are cut into frames at
    whatever paclen is in force when it hands them over.
- Protocol timeouts are stretched by expected on-air time for bytes queued
  at L2 (the peer cannot answer before our bytes finish transmitting).

Checklist:
- [x] Exclusive session byte-stream claim (terminal + AXDP bypass)
  - Implementation notes: `AX25SessionManager.claimDelivery/releaseDelivery`;
    tested in `SessionDeliveryClaimTests`.
- [x] Winlink B2F engine as a pure sans-IO state machine
  - Implementation notes: `AXTerm/Winlink/Protocol/B2FSessionEngine.swift`,
    scripted-dialog tests in `B2FSessionEngineTests` (byte-at-a-time safe).
- [x] LZHUF payload compression, fixture-exact against wl2k-go
  - Implementation notes: `AXTerm/Winlink/Protocol/LZHUF.swift`; interop
    fixtures embedded in `LZHUFFixtures.swift`.
- [x] AX.25 and Telnet transports behind one `WinlinkTransport` interface
  - Implementation notes: `AXTerm/Winlink/Session/`; runner pumps
    transport ↔ engine ↔ store (`WinlinkSessionRunner`).
- [ ] Token-bucket pacing for third-party bulk sends (blocked on §4.3
  pacing being enforced on the live send path generally)

See `Docs/Winlink.md` for the full subsystem design.

---

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
	•	LinkKey = (PeerKey, pathSignature, radioID) — radioID names the radio the link runs on (see Docs/MultiRadio.md); it was the KISS channel before radios existed, and one radio still maps to one KISS port

---

## 17) NET/ROM transport (L3/L4) over connected mode

AXTerm speaks real NET/ROM — the L3 datagram format and the L4 circuit
transport carried in I-frames with **PID `0xCF`** — as node-to-node
protocol, distinct from the 0xF0 terminal relay ("connect and type
`C <dest>`"). The wire format and state machine are transcribed from the
Linux AF_NETROM reference (itself from the ARRL 7th CNC NET/ROM paper),
with exactly three documented deviations.

**Normative details live in `Docs/NetRomTransport.md`.** Summary of the
rules that interact with this spec:

- One L3 datagram per I-frame. PID is the demux: the session machinery
  carries the PID with every delivered payload (including resequenced
  ones), and `AX25SessionManager.onNetRomDatagram` receives 0xCF bytes
  before delivery claims, terminal, or AXDP ever see them.
- Never answer an unmatched NET/ROM frame with a reset — unsolicited
  CONACK|CHOKE replies are documented (in the reference source) to kill
  BPQ nodes.
- Protocol-extension frames (opcode 0: INP3, L3RTT, IP) are carried
  opaque and never interpreted.
- A circuit rides an L2 link to its **next hop**, taken from the route
  table (`bestRouteTo(_:)?.origin`) and **pinned** for the circuit's
  life. The L3 destination is the far station; the AX.25 destination is
  always the neighbor.
- **One datagram, one I-frame.** Fragment size follows the neighbor's
  paclen; an oversized datagram is refused, never split. Note the
  interaction with §4.2: adaptive paclen collapse to 64 under loss
  shrinks NET/ROM fragments accordingly. Since paclen can now fall during
  a session (§7.8.1), a datagram sized before the fall is still sent as
  one I-frame, cut at the session's paclen ceiling rather than its live
  paclen.
- A dropped L2 link fails every circuit pinned to it immediately, rather
  than retrying to N2.
- **Being a node** — announcing (NODES broadcasts) and forwarding
  (transit routing) are both **off by default** and gated on explicit
  settings. Announcing writes this station into other operators'
  routing tables; forwarding commits this transmitter to other people's
  packets. Neither may arrive as a side effect of an app update.
- **Never advertise what this station will not carry.** With forwarding
  off, a NODES broadcast contains exactly one entry: this station. A
  node advertising routes it will not forward is a black hole.
- The NODES destination field is a **callsign**; alias-shaped route
  destinations (EVANS, DRLNOD) are skipped rather than encoded.
- Code: `AXTerm/NetRom/` (codec, circuit state machine, endpoint, link
  driver, circuit-as-session, NODES origination, forwarding, auto-try);
  tests: `AXTermTests/Unit/NetRom/` and
  `AXTermTests/Integration/Relay/NetRomTransportIntegrationTests.swift`.

---

### Final note to implementers
If you’re ever tempted to “optimize” by sending bigger bursts faster: don’t. The most modern, best-behaved packet stations are the ones that share the channel, stay stable under loss, and give users clean explanations of what’s happening.
