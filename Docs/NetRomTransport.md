# NET/ROM Transport (L3/L4)

AXTerm speaks real NET/ROM: the Level 3 datagram format and the Level 4
connection-oriented transport, as carried in AX.25 I-frames with PID
0xCF. This is the protocol BPQ, TheNet, Xrouter, and (historically) the
Linux kernel run between nodes — not the "connect to the node and type
`C <dest>` at its prompt" terminal relay, which remains in `TerminalView`
as the **fallback** when the network cannot carry a circuit. Connecting
in NET/ROM mode tries this transport first; see *Operator surface* below
for how the two relate and what the fallback costs.

**Reference.** The wire format and state machine are transcribed from
the Linux kernel's AF_NETROM stack (`net/netrom/`, last present at
v6.6), whose own comment cites its source: *"taken from page 170 of the
7th ARRL Computer Networking Conference paper"* — NET/ROM's canonical
description. Constants below cite the kernel macro names. Where AXTerm
deviates deliberately, the deviation is listed in its own section; there
are exactly three.

## Files

| File | Role |
|---|---|
| `AXTerm/NetRom/NetRomTransportWire.swift` | L3+L4 wire codec (`NetRomDatagram`, `NetRomL4Frame`, `NetRomTransportWire.parse/encode`) |
| `AXTerm/NetRom/NetRomCircuit.swift` | Circuit state machine (`NetRomCircuitStateMachine`), pure value type, events in / actions out |
| `AXTerm/NetRom/NetRomEndpoint.swift` | Circuit table, handle allocation, inbound matching, timers (`NetRomEndpoint`) |
| `AXTerm/NetRom/NetRomLinkDriver.swift` | Binds the endpoint to real AX.25 links and the route table (`NetRomLinkDriver`) |

Tests in `AXTermTests/Unit/NetRom/`: codec golden vectors + fuzz,
circuit behavior + fuzz (including a lossy-link soak), endpoint
matching, PID demux.

## Wire format

One datagram per AX.25 I-frame (PID 0xCF). Layout:

```
bytes 0..6    origin callsign      AX.25-shifted, E=0, spares 0x60
bytes 7..13   destination callsign AX.25-shifted, E=1, spares 0x60
byte  14      TTL                  decremented per hop; 0 is malformed
byte  15      circuit index  ┐
byte  16      circuit id     │  meanings depend
byte  17      tx sequence    │  on the opcode
byte  18      rx sequence    ┘
byte  19      opcode (bits 0-3) | flags (bits 4-7)
bytes 20..    opcode data
```

Opcodes: 0 protocol-extension (INP3/L3RTT/IP — carried opaque, never
interpreted), 1 CONREQ, 2 CONACK, 3 DISCREQ, 4 DISCACK, 5 INFO, 6
INFOACK, 7 RESET (Xrouter extension — parsed, never emitted, ignored
unless `acceptResets`). Flags: 0x80 choke, 0x40 NAK, 0x20 more-follows.

Per-opcode field meanings (`nr_write_internal`):

- **CONREQ** `[myIdx, myId, 0, 0]` + data `window(1) user(7) node(7)`
  + optional `t1 lo, t1 hi` (little-endian seconds — the BPQ
  extension; detection is by data length, 15 vs 17).
- **CONACK** `[yourIdx, yourId, myIdx, myId]` + data `window(1)`
  + optional `ttl(1)` (sent only to a peer that used the extension).
  Choke flag = **refusal**: same field order, acceptor's handle zeroed,
  one zero data byte. The exotic `[0,0,idx,id]` shape
  (`__nr_transmit_reply(mine:1)`) is normalized on parse, never emitted.
- **DISCREQ / DISCACK** `[yourIdx, yourId, 0, 0]`, no data.
- **INFO** `[yourIdx, yourId, txSeq, rxSeq]` + payload (≤ 236 bytes,
  `NR_MAX_PACKET_SIZE`). `rxSeq` piggybacks a cumulative ack.
- **INFOACK** `[yourIdx, yourId, 0, rxSeq]`. NAK = "retransmit from
  rxSeq"; choke = "stop sending".

Sequence numbers are modulo 256; the window is capped at 127.

## Circuit behavior (kernel-faithful)

- **Connect**: CONREQ, T1 retries up to N2, refusal → `.refused`.
  Window: the responder takes `min(proposed, own)`; the initiator
  adopts the returned value, clamped to its own proposal (a hardening —
  see the end of the deviations section). T1 is negotiated down to the
  peer's advertised value on accept.
- **Send**: fragments at 236 bytes, MORE flag on all but the last
  (`nr_output`); `nr_kick` fills the window, piggybacking N(R) on every
  INFO (which satisfies any pending delayed ack, `vl = vr`).
- **Acks**: in-sequence INFO arms the T2 delayed ack
  (`NR_COND_ACK_PENDING`); a full receive window acks immediately.
  `nr_enquiry_response` adds NAK when out-of-order frames are being
  held, choke when the app is busy — and never NAK while choked.
- **Receive**: out-of-order frames within `[vr, vl+window)` are held in
  a resequence buffer and delivered when the gap heals (the kernel's
  drain loop). Stale duplicates are not re-delivered but still elicit
  an ack — a peer whose INFOACK was lost must not stall.
- **Loss**: T1 requeues all outstanding frames and resends from `va`
  (go-back-N); a peer NAK acks below `rxSeq` and retransmits exactly
  the oldest outstanding frame (`nr_send_nak_frame`).
- **Choke**: peer choke stops the transmit pump and arms T4 (180 s);
  cleared by any unchoked ack or T4 expiry.
- **Disconnect**: DISCREQ/DISCACK with T1 retries; a DISCREQ from the
  peer is acked and honored; DISCACK (or a refused CONACK) out of the
  blue is a reset. Crossing DISCREQs resolve.
- **Reassembly**: MORE-flag chains accumulate and deliver as one record.

Defaults (`NetRomCircuitConfig`, kernel names): window 4
(`NR_DEFAULT_WINDOW`), T1 120 s, T2 5 s, T4 180 s, N2 3, TTL 25 (BPQ
convention; the kernel default is 16).

## Endpoint behavior

- Handle allocation mirrors `nr_find_next_circuit`: rolling 16-bit
  counter, both halves nonzero, live pairs skipped.
- Inbound matching mirrors `nr_rx_frame`:
  - CONREQ → match by *their* handle + origin (`nr_find_peer`); a match
    means our CONACK was lost, so it is repeated. No match → the
    acceptor callback decides; with no acceptor everything is refused.
  - Everything else → match by *our* handle (`nr_find_socket`), with
    the zero-index refusal shape folded in by the parser.
  - **No match → ignored.** Never answered with a reset: the kernel
    source records that unsolicited CONACK|CHOKE replies kill BPQ
    boxes, and opcode-7 is an Xrouter-only extension.
- A datagram whose L3 destination is not this node is logged and
  dropped: this is an endpoint, not (yet) a router. When the router
  half is built, this is its hook.
- An unroutable outbound datagram fails the circuit with
  `.transportFailure`.

## PID demux (how datagrams reach the endpoint)

Node-to-node NET/ROM traffic rides ordinary connected AX.25 sessions,
multiplexed by PID: 0xF0 is terminal text, 0xCF is NET/ROM. The PID now
travels with every I-frame payload through the session state machine —
`receivedIFrame(… pid:)` → `BufferedIFrame.pid` → `deliverData(_, pid:)`
— so a payload that waited in the resequencing buffer still remembers
which protocol carried it. `AX25SessionManager` demuxes at delivery:
0xCF payloads go only to `onNetRomDatagram` (one I-frame = one
datagram), everything else flows to delivery claims / terminal / AXDP
exactly as before.

## Deliberate deviations from the reference

1. **NAK resend keeps T1 running.** The kernel stops T1 after answering
   a NAK with one retransmission; if that lone frame is lost, nothing
   retries. We restart T1 instead — worst case a duplicate, which the
   protocol dedups.
2. **Idle T1 does not count toward N2.** In the kernel, a T1 expiry
   with nothing outstanding still increments `n2count` and can tear
   down a healthy circuit. We stop the timer and reset the counter.
3. **Reassembly is capped** (64 KB per MORE-chain, configurable).
   Exceeding it fails the circuit with a protocol error. The kernel
   chokes instead, stalling the circuit forever with no visible cause.

Two hardenings that are not behavior changes against a sane peer: a
CONACK cannot inflate our window beyond what we proposed (the kernel
adopts the returned byte blindly), and a zero proposed window is
treated as absent rather than adopted (the kernel would deadlock).

## Link driver: how a circuit reaches a radio

`NetRomLinkDriver` is the seam between the transport and AX.25. It owns
three decisions and nothing else:

1. **Which neighbor carries a destination.** Resolved once from
   `NetRomIntegration.bestRouteTo(_:)?.origin` — the neighbor whose
   NODES broadcast advertised the destination — and then **pinned** for
   the circuit's life. Route quality decays and re-ranks continuously; a
   circuit that switched next hop mid-stream would strand its sequence
   state at the old neighbor. Inbound traffic pins the reverse direction
   to the neighbor it actually arrived on, so both directions agree.
2. **Whether a datagram fits.** One datagram must ride one I-frame — the
   receiver parses each I-frame as a whole datagram, so a split one
   decodes as garbage. Fragment size is set from the neighbor link's
   paclen when the circuit opens (`maxInfoPayload = paclen − 20`), and
   an oversized datagram is refused rather than split. **This matters on
   a real link:** AXTerm's adaptive layer collapses paclen to 64 under
   loss, which would otherwise split a 236-byte NET/ROM payload across
   two frames.
3. **What a dead link means.** When the L2 session to a neighbor drops,
   every circuit pinned to it fails at once with a plain explanation,
   instead of retrying into a dead link until N2.

Wiring in `SessionCoordinator`:

- `sessionManager.onNetRomDatagram` → `driver.handleInboundDatagram`
- `NetRomSessionTransport` → `sessionManager.sendData(pid: 0xCF)`,
  which opens the L2 link and queues the datagram behind the SABM when
  the link is down
- `onSessionStateChanged` → `driver.neighborLinkDropped`
- `driver.onOperatorNote` → the Terminal transcript
- `driver.onCircuitsWillChange` → the coordinator's `objectWillChange`,
  because a nested ObservableObject does not republish through its owner

**Operator surface.** Two ways in.

*Explicitly:* Routes page → right-click a destination → *Open NET/ROM
Circuit (native)*. Live circuits appear in the Terminal sidebar under
**NET/ROM circuits**, each with its neighbor and a close button.

*By default:* every *Connect (NET/ROM)* from the connect bar now tries a
native circuit **first**, and only falls back to driving node command
prompts when the network cannot carry one. This reversed an earlier
decision to keep the two strictly separate. The reasoning that changed
it is the field capture of 2026-08-27: connecting to COSCO produced a
transcript full of node menus and 41 seconds of `C DRLNOD` / `C
KB5YZB-7` / `C COSCO` typed at three command interpreters, every frame
carrying PID 0xF0, under a UI that said "NET/ROM". A mode named after a
protocol should try that protocol. Separate buttons meant the working
transport was reachable only by an operator who already knew it existed.

The fallback is not silent — both paths announce which one is running,
and `NetRomRelayPlan.operatorSummary` says outright that node menus are
coming — and it is not free either. Falling back costs
`nativeCircuitGrace` (30 s), so `SessionCoordinator` remembers a
destination whose circuit did not come up and skips straight to the
relay for an hour (`netRomNativeRetryInterval`). That matters because
there is a standing reason a circuit may *never* complete on a given
network: a CONACK has to be routed home, and no node routes to a station
it has never heard advertise itself. With `netRomAdvertiseSelf` off —
the default, and deliberately so — the reply has nowhere to go however
well the outbound half worked. The fallback notice says this when the
setting is off, because it is a setting rather than a fault.

Ordering is the same from `connectNETROM` (one explicit next hop) and
`executeNETROMAutoAttempt` (auto), because those are the operator's two
buttons for one intent and it would be strange for them to use different
transports.

## Being a node: announcing, forwarding, auto-try

AXTerm has *listened* to NET/ROM routing for a long time — NODES
broadcasts via `NetRomBroadcastParser`, plus `NetRomPassiveInference`,
which infers routes from overheard traffic with no broadcast at all,
with decay, link quality and SQLite persistence. What was missing was
never the learning; it was speaking and acting.

### Announcing (`NetRomNodesBroadcast`)

A UI frame to `NODES`, PID 0xCF, standard 21-byte entries with an origin
alias — validated by round-tripping our encoder through the same parser
that reads real BPQ and TheNET broadcasts off the air.

Two rules are enforced in `advertisement(...)` rather than left to
callers:

1. **Never advertise what we will not carry.** With forwarding off, the
   only entry is this station itself, at quality 255. Advertising a
   learned route we would not forward makes this station a black hole:
   neighbours route traffic at it and the traffic dies.
2. **Split horizon** — never advertise a destination back toward the
   neighbour we reach it through.

Plus two guards the field data demanded: zero-quality routes are not
offered, and **alias-shaped destinations are skipped**. The route table
genuinely holds `EVANS` and `DRLNOD` — tactical names with no digit —
and the destination field on the wire is a *callsign*. Encoding one
emits bytes every conforming parser rejects (ours included; that is how
the bug was found).

### Forwarding (`NetRomForwarding.decide`)

A pure function, because every branch is a way to hurt a shared channel:
TTL decremented and dropped at zero (`nr_route_frame`), never sent back
down the link it arrived on, never handed to ourselves, dropped when no
route is known, and dropped rather than fragmented when it will not fit
the next hop's frame. The origin is never rewritten — we are transit.

### Auto-try (`NetRomAutoTryPolicy`, `NetRomAutoTryCampaign`)

Walks candidate hops best-first (`NetRomRouter.candidateRoutes`, dedup
by neighbour, deterministic tie-break). The distinction that matters:

- **the path failed** (`timedOut`, `transportFailure`) → try the next hop
- **the station answered** (`refused`, `reset`, closed) → stop

A node that refuses has been reached; asking again through a different
neighbour is not persistence, it is nagging a station that already
replied. Auto-try is not a retry *loop* over one hop either — T1/N2
inside the circuit already does that, and doubling it would key the
transmitter far more than the network deserves.

### Defaults, and why

`netRomAdvertiseSelf` and `netRomForwarding` both default **off** and
live in Settings → Transmission → NET/ROM Node. Announcing writes this
station into other operators' routing tables; forwarding commits this
transmitter to other people's packets. Neither should arrive as a side
effect of an app update. Auto-try is an explicit operator action on the
Routes page, not a background behaviour.

## Names vs addresses

NET/ROM addresses stations by **callsign**; operators, node tables, and
this app's Routes page name them by **alias** — COSCO, EVANS, DRLNOD.
BPQ resolves the alias before building the header, and
`NetRomDestinationResolver` now does the same:

- A name that is already a valid callsign is **never rewritten**, even
  if it also appears in the alias table.
- An alias resolves through `NodeAliasDirectory.callsign(for:)`; the
  L3 header carries `KE0GB-7` while the UI still reads
  `COSCO (KE0GB-7)`.
- **Route lookup tries both names.** The route table is keyed by
  whatever the broadcast said, so a resolved circuit must still find a
  route learned under the alias — otherwise resolution would break
  connections that already worked.
- An **unresolvable** name is sent exactly as typed, not refused: this
  network genuinely answers to aliases at layer 2 (DRLNOD accepts a
  SABM sent to "DRLNOD"), so refusing would break what works. What we
  never do is guess.
- Applies everywhere an address is chosen: opening a circuit, auto-try,
  transit forwarding, and the NODES advertisement — which now
  *resolves* alias-shaped destinations instead of skipping them, with
  the tactical name still travelling in the entry's own alias field.
  Split horizon is compared after resolution, so an alias and its
  callsign cannot slip past each other.

Note the hard limit underneath all of this: an AX.25 address field holds
**six characters**, which is why NET/ROM aliases are six. Resolving a
longer name to a real callsign is the only way it can be addressed at
all.

## Not yet built (explicitly out of scope here)

- **Inbound services** — the acceptor callback exists; nothing
  registers one, so inbound connects are refused with the standard
  kernel-shape refusal. A station running no services should refuse.
*(The circuit-as-session work is done — see below.)*

## A circuit is a session

CLAUDE.md §5 lists NET/ROM circuits as one of AXTerm's session types, so
a circuit joins the existing session machinery rather than growing a
parallel UI. `NetRomCircuitSession` holds the pure part:

- **Record ids** are namespaced `netrom-circuit:<uuid>`, so they can
  never collide with AX.25 records (keyed by destination + path).
- **Live circuits mirror into `sessionRecords`**, so a circuit appears
  in the Sessions picker with the same status vocabulary the AX.25
  records use ("Connected", "Disconnected" — the *Clear Closed* button
  keys off that exact string). A newly opened circuit selects itself.
- **`sendTarget(activeRecordID:circuits:)`** decides where composed text
  goes. It refuses to send into a circuit that is connecting, closing,
  or already closed, and says why — the same reasoning as the relay
  handshake guard: the words are meant for the far end, and there is
  nowhere to put them yet. Critically, a *closed* circuit record does
  not fall through to the AX.25 path, which would transmit the
  operator's text somewhere they did not intend.
- **Disconnect on a focused circuit** sends DISCREQ on that circuit, not
  DISC on the neighbor link — that link may be carrying other circuits.
- **Focusing a circuit record does not repoint the connect bar.** Doing
  so would make Connect start a *relay* to the same station, which is a
  different mechanism.

Inbound payload is appended to the transcript attributed to the far
station (`onCircuitData` → `appendSessionChatLine`); outbound text is
echoed locally, because the frames we actually transmit are datagrams
addressed to the neighbor and would never read as conversation.
