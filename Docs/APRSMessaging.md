# APRS Messaging & Reachability

AXTerm speaks the standard APRS message layer so it interoperates with the
wider APRS world — other clients, i-gates, digipeaters — not a private
protocol. Messages ride as ordinary AX.25 **UI frames, PID 0xF0**, in the
standard APRS format. This is deliberately *not* the app's own AXDP envelope
(see `AXTERM-TRANSMISSION-SPEC.md` §6): AXDP is for AXTerm-to-AXTerm
reliability, APRS is for talking to everyone.

## Wire format (`AXTerm/APRS/APRSMessage.swift`)

Pure parser/encoder, golden-tested (`APRSMessageTests`). The info field's data
type identifier selects the form:

- **Message** — `:AAAAAAAAA:text{NNN` — nine-character space-padded addressee,
  up to 67 chars of text, optional 1–5 char message number. A number present
  means the sender wants an acknowledgement.
- **Ack / Reject** — `:AAAAAAAAA:ack{NNN` / `:…:rej{NNN`.
- **Bulletin / announcement** — addressee `BLN…`, stored read-only.
- **Directed query** — a message whose text is a query token, e.g. `?APRSP`.
- **General query** — data type `?` (broadcast); parsed, never auto-answered
  (answering every `?APRS?` on a busy channel is a storm).
- **Third-party** — a `}`-wrapped frame (relayed by an i-gate) is unwrapped
  once and its payload re-parsed, so a relayed message still reads.

Positions remain the job of `APRSParser`; this layer is everything it returns
`nil` for.

## Receive, auto-reply, and delivery (`APRSMessagingService`)

Inbound message-class frames are parsed in `PacketEngine.handleIncomingPacket`
(`detectAPRSMessage`, beside the AXDP detector) and handed to the service with
the sender, our callsigns, the radio it arrived on, whether it was heard
**direct** (no digipeater repeated the frame), and the reverse-path for a
reply.

- A **message addressed to us** is stored (unread) and, unless the mode is
  Manual, **auto-ACKed**. A duplicate re-send is re-ACKed but not stored or
  counted twice.
- An incoming **ACK** resolves the matching outgoing message → `acked`, and is
  the connectionless channel's proof of a round trip — the basis of
  reachability. A **reject** fails it.
- A **directed query** is answered in Full mode: `?APRSP` → our position;
  `?APRST`/`?PING?` → `PATH= <sender>><the digipeaters it came through>`;
  `?APRSV`/`?VER` → version; `?APRSD` → the stations we've heard direct.
  `?APRST` used to answer with a position, which answers `?APRSP`'s question
  instead of its own — the query asks *how your frame reached me*, and the
  path is the only thing that answers it.

Outgoing numbered messages are retried on a conservative ladder —
**30 / 60 / 120 / 240 / 480 s, five attempts** — then marked `failed`. A late
ACK never revives a failed or already-acked message. Everything persists in
the `aprs_messages` table (`APRSMessageStore`, migrations v32 + v33).

### Auto-reply modes (Settings → Transmission → APRS Messaging)

Because replies transmit **under your callsign**, the behaviour is an
operator-owned, persisted choice, read live:

- **Full** — auto-ACK messages *and* answer directed queries. (default)
- **ACK only** — auto-ACK messages; ignore queries.
- **Manual** — never transmit without you pressing send.

## Who can hear me? (`APRSReachabilityProbe`, Xastir-style)

Transmits **one** unaddressed general query — `?APRS?` to the APRS tocall — on
each of the operator's **APRS radios**, and listens. Every APRS station in
earshot answers on its own with a position/status; each is tallied as it
arrives and classified **direct** (heard with no digipeater) or **via a
digipeater**. This is a flood, not a directed poll: one transmission per APRS
channel instead of a directed query per station, and because `?APRS?` is
meaningful only to APRS stations, the plain AX.25 nodes, BBSes and digipeaters
on the channel are never addressed and never bothered. Normal message ACKs feed
the same reachability picture.

**Which radios carry it.** A `?APRS?` flood only belongs on an APRS channel —
never on a node/BBS frequency. So the flood (and an APRS message with no route
of its own) goes out only radios that carry APRS: `SessionCoordinator.connectedAPRSRadios()`
= the enabled, connected radios where `RadioProfile.handlesAPRS` is true.
`handlesAPRS` is the per-radio **APRS** toggle (Settings ▸ Radios ▸ Services),
or automatically true when the radio beacons an APRS position — so a typical
APRS radio needs no setup. A single-radio station has no other channel to
confuse it with, so its one radio always counts. When no APRS radio is
connected, the probe doesn't pretend to listen: it reports *"Couldn't transmit
— no connected radio has APRS turned on."*

Because a general query solicits everyone in earshot, it can't be *aimed* at a
class — so the scope (`APRSProbeScope`) is a **view filter** on the results, not
a transmit-time choice:

- **All** — every station that answered.
- **Infrastructure** — fixed relays: digipeaters, i-gates, gateways, repeaters
  (`#`, `&`, `I`, `r`).
- **Moving** — reporting course/speed, or wearing a vehicle/aircraft symbol.

The candidate/silent set is drawn only from stations with a decoded APRS
position (`PacketEngine.aprsHeardStations()`), never from plain packet nodes.
Stations heard just before the flood but silent afterward are listed separately.

**Inherent caveat.** A general query can't perfectly distinguish a solicited
reply from a station's routine position beacon that lands inside the listening
window. The 120 s window keeps that unlikely at normal beacon rates; fast Mic-E
movers are noisier. The map's **Ping** (a directed `?APRSP` to one chosen
station) stays the clean per-station reachability test.

## Asking one station (`APRSDirectedQuery`, `APRSAskStationSheet`)

The counterpart to the channel-wide flood. A directed query is a message to a
single station: one transmission, at most one answer, and a question about
*that* station rather than about the room.

Seven are offered, and they are not interchangeable — **what comes back is the
thing that matters**:

| Query | Reply | Provable |
| --- | --- | --- |
| `?APRSP` | position report | no — a broadcast |
| `?APRST` (`?PING?`) | `PATH= …` message | **yes** |
| `?VER` | version message | **yes** |
| `?APRSD` | `Directs= …` message | **yes** |
| `?APRSS` | status | no — a broadcast |
| `?APRSO` | objects & items | no — a broadcast |
| `?APRSM` | held messages | **yes** |

`APRSDirectedQuery.answer` carries that distinction and the UI shows it on every
row as *Replies to you* vs *Broadcasts*, because it is the one fact an operator
cannot read off the query's name and cannot recover afterwards: a `?VER` reply
is proof the station heard you, while a `?APRSP` reply is a beacon that may have
been on its way regardless (see **Did they answer?** above).

`axtermAnswersIt` marks the four this station answers itself. It is asserted
against `receiveQuery` in `APRSDirectedQueryTests`, so the badge and the
behaviour cannot drift apart.

**Two ways in, one action.** The map's station card carries a split button:
clicking **Ping** still sends `?APRSP` in one click, its menu lists all seven,
and *Ask…* opens `APRSAskStationSheet` — the full picker, with what each query
replies with, a reach control, and the last result for that station in the
header so the dialog is also where the answer lands. Everything funnels into one
`APRSStationQuery` (callsign, token, reach), so a query typed by hand travels
the same road as one picked from the list.

**Reach is the operator's.** *Direct only* sends with no path, so an answer
proves earshot; *Via my APRS path* uses the radio's own path, so an answer
proves reachability but not earshot. Remembered separately from the flood's
reach — a directed question and a channel-wide one are different decisions.

**Typed queries.** `?APRSH`, `?IGATE?` and the station-specific queries some
software invents have wire formats this app has no authority over, so there is a
free field instead of guessed rows. Typed text is normalised the way the spec
writes queries — upper-cased, leading `?` — because Xastir (and anything else
following the spec) rejects a lowercase query as illegal rather than guessing.

## UI

One `APRSMessagesView` backs every platform, in two shells: `.standalone`
(a `NavigationSplitView` — the macOS sidebar item and the iPad tab) and
`.pushed` (a plain list that drills into the conversation on the navigation
stack it's already inside — the iPhone More list, so it never draws a second
back button). It carries a **Message** item everywhere with an unread badge,
plus **Message**/**Ping** actions on the map station card (Ping is a targeted
`?APRSP`).

The look is a familiar chat — thread list, bubbles, a compose bar — but honest
about RF rather than an iMessage clone, because APRS is best-effort,
unencrypted, and low-rate:

- **Delivery is told straight.** Outgoing state reads *Queued → Sent · awaiting
  ack → Acked → No ack · N tries*; an unnumbered message shows *Sent · no ack*
  because it solicits none. No checkmark that implies a guaranteed private
  delivery APRS never offers.
- **The RF facts iMessage has no slot for are surfaced**, not hidden: incoming
  is tagged **direct** vs **via digi**, and a caption shows the message number
  (`#042`) and path (`via WIDE2-2`).
- **Bulletins** are a read-only broadcast card (no compose — you can't reply to
  a bulletin), and **queries** (`?APRSP` …) render as monospace system rows,
  not as a fake chat partner.
- The compose bar shows a live `count/67 · unencrypted RF` caption.

The iOS shell runs the same engine (auto-reply, probe) through the shared
wiring and now the shared screen — an iPad tab and an iPhone More-list row,
both unread-badged.

## Tests

`APRSMessageTests`, `APRSMessageStoreTests`, `APRSMessagingServiceTests`
(async `@MainActor`), `APRSStationClassTests`, `APRSReachabilityProbeTests`.

### Checked against Xastir, executably

"AXTerm matches Xastir" used to be a prose comment: the source was read and the
behaviour written down. Nothing failed when the reading was wrong — and twice it
was. The rig now runs **real Xastir 2.1.8 as a station on the simulated
channel** (`TestRig/xastir`, `docker compose --profile aprs up -d`) and
`TestRig/scripts/xastir_oracle.py` captures its replies byte-exact into
`AXTermTests/Fixtures/xastir-oracle*.json`. The fixtures are checked in, so the
assertions run in CI without Docker.

Three suites use them:

- **`XastirOracleTests`** — what the reference implementation does. Which
  queries it answers with a message and which with a broadcast; that directed
  answers arrive in about a second; which queries it declines.
- **`XastirDifferentialTests`** — AXTerm answering the same questions over the
  same paths, compared byte-for-byte against the capture.
- **`XastirMessageRoundTripTests`** — the other direction: our encoder against
  Xastir's decoder. An `ack` coming back proves it found our 9-character padded
  addressee and message number exactly where the spec puts them.

**Two real bugs, found within minutes of the oracle existing:**

1. `?APRST` is answered `PATH= <sender>><DESTINATION>[,<every via, in order>]`.
   Reading the format string `"PATH= %s>%s"` in `db.c` and guessing at what
   Xastir passes as `path`, AXTerm emitted `sender>digis` and dropped the
   destination entirely.
2. `?APRSD` is `Directs=` with **a space before every callsign**, including the
   first — Xastir appends `" " + call` per station. AXTerm joined with a
   separator and lost the leading space.

Both are the same class of error and neither was catchable by reading.

### Against the specification

`APRSSpecVectorTests` asserts the shapes APRS Protocol Reference 1.01 states,
with the chapter cited on each: the nine-character space-padded addressee and
the reference's own `:WU2Z     :Testing{003` example (ch.14), `ack`/`rej`
format, the 1-to-5 character message number, the 67-character text cap,
bulletin addressees, directed queries riding inside a message and general
queries not being messages at all (ch.15), the destination carrying a tocall
and never the recipient (ch.5), and third-party unwrapping (ch.17).

This is deliberately separate from `APRSMessageTests`, which checks that our
encoder and parser agree with each other — a closed loop that stays green when
both are wrong together.

### Over real AFSK

The captures above run on the kisshub, which copies frames between clients.
`AXTermTests/Fixtures/xastir-oracle-rf.json` is the same interrogation over
`TestRig`'s `rfnet` profile, where each station has **its own Direwolf** and all
of them share one audio bus — every frame genuinely modulated and demodulated,
with per-modem DCD and slot timing.

`XastirRFParityTests` asserts what that buys: the protocol answers are
byte-identical on both channels, the unanswered set is the same, and only the
timing changes — 1.9–3.9 s over the air against ~0.9 s on the hub. Both are
comfortably inside `APRSPingTracker.window`, which is the measurement behind
calling that window generous rather than tuned.

`?APRSD` is excluded from the byte comparison and checked for shape instead: it
reports the stations that Xastir has actually heard, so its content legitimately
differs between two runs.

### AXTerm's own transmissions, proven on the air

Everything above tests AXTerm's *answers*. `AXTermOnAirTests` and
`AXTermOnAirResultTests` test its *transmissions* — the queries, the ping, the
message and the beacon — which no amount of self-consistent round-tripping can
establish, because a frame our own parser accepts may still be one nobody else
does.

The proof is deliberately split so that neither half rests on the code under
test:

1. `TestRig/scripts/axterm_onair.py` builds the frames with **its own**
   encoder, transmits them on `rfnet`, and records what came back.
2. `AXTermOnAirTests` asserts AXTerm's production path —
   `APRSMessage` → `AX25FrameBuilder.buildUI` → `OutboundFrame.encodeAX25()` —
   emits byte-identical frames.

Measured, on a shared 1200-baud AFSK channel:

| We transmitted | What happened |
| --- | --- |
| `?APRSP` (the map's Ping) | a position report addressing nobody — the reason `APRSAnswerEvidence` exists |
| `?VER` | `:ORACLE-1 :xastir 2.1.8` — a message to us, the provable class |
| `?APRSD` | `Directs= 147.285CO AD1CT AID KK0X-10 N2XGL-1 ORACLE-1` **and** `Directs= SIMLA WT0R-9` — it continues into a second message rather than truncating |
| `?APRST` via `WIDE1-1` | **two** answers: `PATH= ORACLE-1>APZAXT,WIDE1-1` for the copy heard direct and `PATH= ORACLE-1>APZAXT,RFDIGI-1*` for the one a real digipeater repeated |
| message `…{042` | `ack042` — our nine-character addressee and message number found exactly where ch.14 puts them |
| position beacon | no reply, correctly; Direwolf's parser read it as *Position, House, Experimental / N 39 36.7000, W 104 43.9000* |
| **compressed** beacon | *N 39 36.7019, W 104 43.9021* — 39.61170 / −104.73170, the exact fix we base-91 encoded |
| `?APRS?` | answered at **+89.7 s** — inside Bruninga's random 0–120 s spread |

Three implementations are involved and only one of them is ours: Xastir answers
the queries, Direwolf decodes the beacons, and Direwolf's digipeater repeats the
traced frame. `testOurTocallIsReadAsExperimentalByAnotherImplementation` pins
that `APZAXT` reads as experimental — the same reading aprs.fi gives.

Direwolf also classifies every frame by type without being told what it is
(`testAnotherImplementationClassifiesEachTransmissionCorrectly`): our directed
queries as *Directed Station Query*, `?APRS?` as *General Query*, and the
message as `APRS Message 042 for "XASTIR-1"` — ch.14's padded addressee and
`{` number both read back to us out of the bytes.

The compressed beacon is the one that most needed this. `APRSBeacon`
has always been able to transmit base-91 and never had, and base-91 is exactly
the encoding where a wrong divisor still produces a well-formed frame at the
wrong coordinates: our own decoder would have read our own mistake back
faithfully. Direwolf's reading — 39.61170 / −104.73170 against the 39.6117 /
−104.7317 we encoded — is what settles it, and
`testTheTwoBeaconEncodingsAgreeOnTheAir` holds the two encodings to each
other's fix as heard, not as intended.

The general-query timing is the empirical basis for
`APRSMessagingService.generalQueryWindow`: a directed query is answered in
about two seconds on RF and the broadcast one after a minute and a half, which
is the difference between answering on receipt and scheduling.

#### A fourth divergence: `Directs=` continues, it does not truncate

The `?APRSD` capture above named eight stations across **two** messages. We
were building one and cutting it at ch.14's 67-character limit with
`String.prefix`, which can slice a callsign in half — `W0ARP-10` arriving as
`W0AR` is not a shorter answer, it is a wrong one naming a station that was
never heard. `APRSMessagingService.directsAnswers` now packs by callsign and
continues into further messages, capped at `directsMessageLimit` (3) because a
busy station hears more than anybody asking wants transmitted at them.

Xastir broke earlier than the limit — at 53 characters, where 66 would still
have fitted — which is its own buffer rather than a rule in the specification,
so we pack to the limit the specification gives.

Worth noting and deliberately *not* copied: Xastir's list included objects and
items (`147.285CO`, `AID`) alongside stations, because it keeps them in the
same database. Ours lists stations that transmitted.

### Every type we can read, read back by somebody else

AXTerm transmits positions and messages. Objects, items, telemetry, weather,
status and Mic-E are **parse-only**, so no round trip through AXTerm can ever
prove them — our encoder and our decoder agreeing is one implementation
agreeing with itself, which was the closed loop worth breaking.

`TestRig/scripts/aprs_zoo.py` puts one frame of each type through a real modem
and records what Direwolf — neither AXTerm nor Xastir — made of it.
`APRSZooTests` then asserts AXTerm reaches the same conclusions.

| Type | Direwolf's reading | What it pins |
| --- | --- | --- |
| Mic-E (`WT0R-9>SYTPZZ`) | *MIC-E, FIRE TRUCK, Off Duty / N 39 40.0000, W 104 45.0000, course 29, alt 5722 ft* | latitude, signs and message bits live in the **AX.25 destination** (ch.10) — `testMicELatitudeComesFromTheDestinationField` changes the destination and requires the position to move |
| compressed position | *N 39 37.3639, W 104 46.3539, alt 5815 ft* | base-91 and `/A=`, with the altitude stripped back out of the comment |
| uncompressed position | *N 39 34.1500, W 104 55.0500* | the ordinary case |
| object (`;`) | *Object, "147.285CO", N 38 26.7800, W 106 00.6500* | the padded 9-character name, the live/killed flag, the fix |
| item (`)`) | *Item, "AID"* | 3-to-9 character name, no timestamp (ch.11) |
| telemetry | *Seq=212, A1=185 … D8=0* | every channel named, so the classic off-by-one split cannot survive |
| weather | *temperature 65, humidity 42, barometer 30.01, gust 1, rain 0.00* | ch.12 field by field — including the unit crossing, since Direwolf reports inches of mercury and we keep tenths of millibars |
| status (`>`) | *Status Report* | carries no fix; `testFramesWithoutAFixYieldNoPosition` requires we invent none |

Most of these are real transmissions off the operator's own channel
(2026-09-09), reconstructed from the RX trace; the rest are synthesised to
APRS 1.01, and Direwolf decoding them **at all** is what validates the
synthesis, since a malformed frame simply is not decoded.

One divergence, recorded and not asserted: Direwolf calls `/r` a *Repeater* and
our symbol catalogue calls it an *Antenna*. Both names are in circulation; the
symbol character is the protocol and the label is not, so the tests compare
characters.

### Against the live network (`LiveFeedParityTests`)

The zoo proves one frame of each type. This is the other axis: **every frame
two feeds carried in the same half hour** — our own radios on 144.390, and the
APRS-IS stream aprs.fi displays for the same 150 km — decoded by `decode_aprs`
and then by us. 1142 frames, captured 2026-09-09 15:20–15:50Z with
`TestRig/scripts/live_feed_capture.sh`.

Live traffic is where the malformed and the merely unusual live, and it found
two things a corpus of well-formed fixtures never would:

- **A Mic-E beacon with no GPS fix.** NI0W-9's destination was `PPP0PP` — every
  latitude digit zero. Decoded literally that is 0°N 0°E, in the Gulf of
  Guinea, 13 000 km from the station that sent it. `APRSParser` now refuses the
  exact origin as a position: a dot at coordinates nobody transmitted is worse
  than an unplaced station, and on a map that fits its stations, one of them
  drags the view off Africa.
- **A course of 579°.** A corrupted copy of another NI0W-9 frame, gated by
  N0IGD. The position in it was fine and is kept; the course is not a bearing
  and is now dropped. APRS writes due north as 360 and "unknown" as 0, so both
  ends of the range are real and the guard keeps them.

Three harness lessons are worth recording, because each one silently produced a
"finding" that was not one:

- Feeding a raw APRS-IS line to `decode_aprs` fails whenever the q-construct
  names a server longer than a callsign (`T2ALBERTA`) — it parses TNC2 as
  AX.25. Strip the construct and everything after it before decoding.
- APRS-IS carries stations that have no AX.25 existence: MMDVM gateways with
  letter SSIDs (`W0KVZ-N`), LoRa gateways with SSID 40, `WINLINK` at seven
  characters. Direwolf refuses them; we parse an information field and neither
  know nor care. No such frame can reach AXTerm from a radio, so the comparison
  skips them.
- The suite once passed three assertions over an empty array, because the
  fixture would not decode. `testTheCaptureLoaded` and a `compared > 300` floor
  exist so a comparison cannot quietly stop comparing.

### Regenerating the fixtures

    cd TestRig && docker compose --profile aprs up -d
    cd scripts
    python3 xastir_oracle.py --listen 9 --attempts 3 \
      --queries "?APRSP,?VER,?APRSD,?APRST,?PING?,?APRSS,?APRSO,?APRSM,?APRSH,?IGATE?,?aprsp,?WX?" \
      --out ../../AXTermTests/Fixtures/xastir-oracle.json
    python3 xastir_oracle.py --messages 'Testing{003;spec-min{1;spec-max{99999;no-number-here' \
      --out ../../AXTermTests/Fixtures/xastir-oracle-messages.json

Over real RF (`docker compose --profile rfnet up -d`), which also needs the
digipeater and AXTerm's own transmissions:

    python3 xastir_oracle.py --port 8013 --out ../../AXTermTests/Fixtures/xastir-oracle-rf.json
    python3 digi_capture.py --out ../../AXTermTests/Fixtures/rf-digipeater.json
    python3 axterm_onair.py --out ../../AXTermTests/Fixtures/axterm-onair.json \
      --frames-out ../../AXTermTests/Fixtures/axterm-onair-frames.json
    python3 aprs_zoo.py --out ../../AXTermTests/Fixtures/aprs-zoo.json

And against the live network, which needs no rig at all — just the operator's
own radios running and an internet connection:

    ./live_feed_capture.sh 30

`--attempts` exists because the hub is a real half-duplex medium with
collisions: a lost query says nothing about Xastir, and a single silent probe
must not be recorded as "does not answer". Two observations that looked like
findings — a one-character message number going unacked, and a query going
unanswered — were both channel loss, and both evaporated on a retry.

## Answering other stations' queries

A **directed** query (`?APRSP` to us) is answered immediately: it is aimed at
this station alone, so there is nobody to collide with. Xastir does the same —
`process_directed_query` sets `transmit_now` (`src/db.c`).

A **general** query (`?APRS?`, unaddressed) is answered after a random 0–120 s
delay, and the delay is the protocol rather than politeness. Every station in
earshot receives the same frame at the same instant; without a spread they all
answer at once and none of the answers arrive. Bob Bruninga's rule is the random
window, and Xastir implements it by pushing its own next posit out to a random
point inside it (`process_query`). Coalescing falls out of the design: a second
query arriving while an answer is pending does not queue a second answer, which
is exactly why Xastir mutates a posit time instead of queueing replies.

Only `?APRS?` is answered. `?WX?` asks for a weather report and this station is
not a weather station — Xastir leaves that branch unimplemented for the same
reason — and `?IGATE?` asks for igate statistics AXTerm does not keep.

Case is strict. The spec's query tokens are uppercase, and Xastir treats any
other case as an illegal query and refuses it rather than guessing; AXTerm now
matches, for both general and directed queries.

Answering is gated on the auto-reply setting: `full` answers, `ackOnly` and
`manual` do not.

## Did they answer?

A directed `?APRSP` is answered with an ordinary broadcast position report: no
addressee, no reference to the query, byte-identical in kind to the beacon that
station was going to send anyway. **The answer cannot be read off the frame.**
Field capture, 2026-09-08: two `?APRSP` floods at 19:30, followed by a dense
stream of positions — but KB7OKL-1 had transmitted at 19:30:05, :08 and :13,
*before* the first query, and kept beaconing every few seconds throughout. Every
one of those looked like a reply and none of them was one.

`APRSAnswerEvidence` is the arithmetic that separates the two. A routine beacon
landing in a window of `t` seconds has roughly a `t / interval` chance of doing
so by luck, so a station is credited with answering only when its own cadence is
at least `improbabilityFactor` (4) times the elapsed time — a one-in-four
coincidence at worst. The cadence is the **median** gap between that station's
transmissions (`PacketEngine.aprsBeaconIntervals`), sampled when the query goes
out; the mean would let one long silence while a mobile is parked make every
later beacon look like a reply.

The results panel therefore separates *Answered* from *Heard, but beaconing
anyway*, and the status line counts only the first. Section titles also depend
on `APRSProbeReach`: a digipeated query is answered by stations that cannot hear
us at all, so "can hear you" is only claimed for a direct one.

### Pings

`APRSPingTracker` gives a per-station ping the other half of the exchange —
waiting, then one of three outcomes:

- **confirmed** — the station sent us a message addressed to *us*. Proof it
  heard the ping, and the only unambiguous evidence APRS offers. `?VER`,
  `?APRSD` and `?PING?` are answered this way; `?APRSP` never is.
- **likely** — it transmitted improbably soon for its own cadence, by the rule
  above. Evidence, not proof.
- **silent** — the window (120 s) closed with nothing attributable. Not proof
  it cannot hear us: most trackers and many digipeaters never answer queries at
  all.

120 s is generous, not tuned: a directed query is answered on receipt by
anything that answers at all — Xastir's `process_directed_query` sets
`transmit_now` for `?APRSP` (`src/db.c:12893`). The random 0–120 s delay applies
only to the *general* query `?APRS?` in `process_query`, where every station in
earshot would otherwise answer at once. So a ping that is going to be answered
is answered long before the window closes; the rest of it covers a digipeated
round trip and a busy channel.

#### Digipeating is not answering

Alongside the outcome, a ping carries a separate fact: `heardUs`, set when the
station retransmitted one of our own frames while we were listening. It never
changes the outcome, because repeating a frame is not answering it — but it
turns "no answer" into "it hears you and does not answer", which are different
problems with different fixes.

The two are different layers, and software commonly implements one and not the
other. Digipeating happens in AX.25: a station finds its callsign (or an alias
it serves) in the via path, sets the has-been-repeated bit and puts the frame
back on the air without ever looking at the payload. Answering `?APRSP` happens
in an APRS application: parse the information field as a message, compare the
9-character addressee against our own callsign, build a position report. A
fill-in digi, an `aprx` node or a bare digipeater firmware does the first all
day and has no code for the second.

Observed 2026-09-09: AD1CT (`APGRWO`) repeated our query frame twelve seconds
after we sent it, and never answered it. The tracker now reports that as *"It
hears us — it repeated our frame — but did not answer"*, with an antenna rather
than a question mark.

Credit is deliberately narrow. Only the station named in the ping counts, so
K5RHD-10 repeating a query addressed to AD1CT says nothing about AD1CT; and only
a repeat inside the ping's own window counts, so the row speaks about *this*
ping rather than about the link in general.

**Reception outlives the ping.** `repeaters` records when each station last put
one of our frames back on the air, whether or not a ping was outstanding, and
the station card shows it as *"Repeats our traffic · 2 minutes ago"* on its own
line. The narrow per-ping credit above answers "did it hear *this*"; this
answers "can it hear me", which is the question the operator actually has, and
it stays true between pings.

**Reach decides whether silence is informative.** A `.direct` query carries no
digipeater path, so no digipeater can repeat it and the absence of digipeat
evidence means nothing — the ping records its `APRSProbeReach` so the tooltip
can say that rather than implying the station went quiet. Observed 2026-09-09:
four directed queries to AD1CT (`?VER`, `?APRSP` ×2, `?APRSO`), all sent direct,
all unanswered, while AD1CT was visibly digipeating W0AJO's traffic on the same
channel.

`APRSPingTracker.follow` hops the packet publisher to the main queue
(`.receive(on: DispatchQueue.main)`). `PacketEngine.packetInsertSubject` fires on
the decoding thread, and this class publishes to SwiftUI; without the hop it
logs *"Publishing changes from background threads is not allowed"* and races the
render. `SessionCoordinator` hops the same publisher for the same reason.
