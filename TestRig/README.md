# The AXTerm Test Rig

A real LinBPQ node on a simulated shared channel, in docker — so every
protocol feature can be exercised against the genuine article without
keying a transmitter. Nothing here ever touches RF; every callsign in
the rig is fictional and never leaves the compose network.

```
AXTerm (this Mac) ──┐
LinBPQ  BPQTST-7 ────┤   kisshub :8010  ← a real half-duplex medium:
(TSTNOD, sysop :8011)│      airtime, collisions, bit errors
LinBPQ  BPQTX2-7 ────┤      (multi profile)
(FARNOD)             │
KA-Node K0EPI-6 ─────┘      (multi profile — a Kantronics node,
(DRL)                        NOT a NET/ROM router)
```

Every frame takes real airtime (1200 baud: a 100-byte frame is 0.67s),
and two stations keying up at once **collide** — both destroyed, the
way real RF works. Turn it off with `COLLISIONS=0 BAUD=0` for the old
instant, perfect channel.

## Run it

```bash
cd TestRig
docker compose up -d
python3 scripts/smoke.py     # proves the channel + node without AXTerm
```

Then point **AXTerm → Settings → Connection** at `127.0.0.1:8010` and
connect. You are now a station on the same frequency as a real BPQ
node that broadcasts NODES every minute.

**Warning:** disconnect AXTerm from the real TNC first, or use a test
instance — the rig and the radio are different worlds and the app has
one connection.

## What to test against it

| Feature | How |
|---|---|
| NODES learning | Wait a minute; the Routes page should learn TSTNOD/BPQTST-7 with sourceType broadcast. |
| Node connect + scrape | Connect `TSTNOD`, type `ROUTES` — the harvested rows should reach the Nodes page. |
| Aliases | `NODES` at the prompt; the alias directory should learn what BPQ claims. |
| Native circuits | With advertise-self ON, BPQ learns EPINOD; open a NET/ROM circuit to `TSTNOD` — a real CONREQ/CONACK against BPQ's transport. |
| **Our node service** | Telnet to the sysop console (`telnet 127.0.0.1 8011`, user `sysop` pw `sysop`) and: `C 1 EPINOD` — BPQ dials *our* L2 node door. Walk `NODES`, `ROUTES`, `MH`, `BBS`, `C BPQTST-7` (bridge back!), `BYE`. |
| Digipeating | Enable the digipeater, then from the sysop console connect somewhere `VIA K0EPI-7` — the hub log shows the repeated frame with the H bit set. |
| XID / DM answers | AXTerm's XID probe against BPQ answers exactly as the real network does. |
| Rough channel | `LOSS=0.15 DELAY_MS=150 JITTER_MS=100 docker compose up -d kisshub` — retries, REJ recovery, adaptive paclen, T1 behaviour, all under honest loss. |

The hub log (`docker compose logs -f kisshub`) shows every frame on
the channel as `src>dst (n bytes)` — the rig's own monitor.

## The physics (default hub)

The channel is half-duplex and lossy on purpose. Env vars on the
`kisshub` service:

| Knob | Default | What it models |
|---|---|---|
| `BAUD` | 1200 | airtime per frame; set 0 for instant |
| `COLLISIONS` | 1 | overlapping transmissions destroy each other |
| `CAPTURE` | 0 | if 1, the first (stronger) frame survives a collision |
| `BER` | 0 | per-bit errors inside a delivered frame (marginal copy) |
| `LOSS` | 0 | whole-frame fade, independent of collisions |
| `DELAY_MS`/`JITTER_MS` | 0 | extra propagation latency |

```bash
# A busy, marginal channel: collisions + 0.1% bit errors + 10% fade.
BER=0.001 LOSS=0.1 docker compose up -d kisshub
```

The hub logs `## COLLISION`, `* N bit error(s)`, and a rolling channel
tally every 30s. Collisions are the hidden-node problem by construction:
TCP-KISS carries no carrier sense back to the stations, so they cannot
hear each other and must recover from the wreck — which is exactly the
retry/backoff behaviour worth testing.

## The multi-node network (`multi` profile)

```bash
docker compose --profile multi up -d
```

Adds two more stations to the frequency:

- **BPQTX2-7 (FARNOD)** — a second real BPQ node. Now AXTerm sees two
  nodes advertising NODES, competing route qualities, and multi-hop
  paths (reach FARNOD *through* TSTNOD). Tests route selection, tie-
  breaking, and the "best route wins" logic against a real second node.
- **K0EPI-6 (DRL) — a Kantronics KA-Node**, the crucial counter-example.
  It answers connects with `###CONNECTED TO NODE DRL(K0EPI-6)` and
  `ENTER COMMAND: B,C,J,N,?`, runs the KA verbs (C/J/N/B), beacons an
  ID with the `/N` flag — and **never broadcasts a NODES table**. This
  is what the capability classifier exists to tell apart from BPQ:
  DRL's profile must classify as a KA-Node (not NET/ROM-capable), with
  the menu quoted as evidence. Mis-classifying it is the poisoned-route
  bug the classifier was built to prevent.

`scripts/ka_node.py` and `scripts/ax25station.py` (a minimal AX.25
connected-mode station) also run standalone against the hub if you want
to script your own node behaviours.

## Two frequencies (`dual` profile)

```bash
docker compose --profile dual up -d
python3 scripts/smoke_dual.py        # proves both hubs and all three nodes (150 s)
```

Adds a second hub on **:8020** — a second frequency — and two nodes:

- **BPQTX3-7 (CHBNOD)** hears only hub B.
- **BPQTX4-7 (BRGNOD)** has one port on each hub: one NODECALL announced
  on both frequencies under one alias, and L3 forwarding between them,
  so TSTNOD and CHBNOD reach each other through it. This is exactly what
  AXTerm's *one node on every radio* setting does, run by the reference
  implementation.

In AXTerm add two radios, "Hub A" → 127.0.0.1:8010 and "Hub B" →
127.0.0.1:8020 (Settings → Radios) — or launch the built app isolated
from your real station with both seeded:

```bash
"$APP/Contents/MacOS/AXTerm" --test-mode --ephemeral-db --auto-connect \
  --instance-name rig --callsign K0EPI-7 --radios 127.0.0.1:8010,127.0.0.1:8020
```

Then:

- **Routes** lists TSTNOD on Hub A only, CHBNOD on Hub B only, and BRGNOD
  twice — once per radio, with independent qualities.
- The connect bar's **Radio** picker on Auto explains itself: TSTNOD → Hub A
  ("heard BPQTST-7 there …"), BRGNOD → a tie broken by list order → Hub A.
  Set `LOSS=0.3` on `kisshub` and Auto for BRGNOD flips to Hub B, citing
  ETX.
- The sidebar's **Radios** switches hide one hub's traffic everywhere; the
  Packets table gains a Radio column; the status line says "on Hub B".

**Shared channel** needs no rig change: point both radios at :8010. The hub
fans every frame to every client, so both radios hear everything —
exercising the cross-radio fold (one packet, two hearings, dups 0 on both),
own-echo detection, and staggered beacons.

## The node farm — many nodes, seed-driven (`farm` / `multi` profile)

`scripts/nodefarm.py` puts a whole mixed neighbourhood on the channel:
5-10 stations of DIFFERENT packet-OS families, chosen deterministically
from a seed so a run reproduces, and differently across seeds so
coverage broadens. Every family AXTerm must cope with in the wild:

| Personality | What it is |
|---|---|
| `bpq` | NET/ROM node — real NODES broadcasts (PID 0xCF), NODES/ROUTES/MH shell |
| `thenet` | NET/ROM node, TheNet-flavour banner |
| `kanode` | Kantronics KA-Node — `###CONNECTED` / `ENTER COMMAND`, **never** NODES |
| `digi` | pure digipeater — repeats via-addressed frames, refuses connects (DM) |
| `bbs` | a mailbox answered directly, no node level |
| `beacon` | beacons status, refuses connects — a station running no service |

```bash
FARM_SEED=42 docker compose --profile multi up -d   # farm + 2 real BPQ + KA-node
python3 scripts/nodefarm.py --seed 42 --list         # see a population without running
```

Every seed always includes at least one NET/ROM node and one KA-Node,
so the capability classifier's two poles are present every run. The
farm's NODES broadcasts are byte-identical to AXTerm's own wire format —
**pinned in CI** by `RigFarmWireCompatibilityTests`, which parses the
exact bytes `netrom.py` emits through AXTerm's real
`NetRomBroadcastParser`. If the encoder ever drifts, that test fails.

## Validating the fixture

The rig checks *itself* — because a test against an invalid fixture is
worse than no test:

```bash
FARM_SEED=42 docker compose --profile multi up -d
sleep 15                                   # let the channel fill
python3 scripts/validate.py --seed 42
```

It asserts: NET/ROM nodes broadcast NODES that decode cleanly; KA-Nodes
and digipeaters NEVER broadcast NODES; every station in the population
is responsive (actively probed, with retries, because a saturated
channel eats single frames); and collisions actually occur. Exit 0 only
if the fixture is what it claims to be. Validated across seeds 1, 7, 42,
500 — and it caught a real bug on the way (garbage frames crashing
digipeater threads), which is exactly what a fixture validator is for.

## The `rf` profile (experimental)

For modulated-audio realism — real AFSK 1200, real DCD, real TXDELAY,
real collisions — a single Direwolf with a PulseAudio null-sink
loopback stands in for the channel: its TX audio feeds its own RX, so
every KISS client's frame is genuinely modulated and demodulated.

```bash
docker compose --profile rf up -d direwolf-rf linbpq-rf
```

Point AXTerm at `127.0.0.1:8012`. PulseAudio-in-docker is the fragile
part; if direwolf logs no audio device, stay on the hub — it tests
everything above the modem, which is everything AXTerm implements.

## Notes

- LinBPQ is downloaded from G8BPQ's official site at image build (the
  licence permits use, not redistribution — the binary is never
  committed). It is the ARM build, run via Docker Desktop's arm/v7
  support.
- `NODESINTERVAL=1` and other timers are deliberately fast; this rig
  exists to exercise learning, not to model channel etiquette.
- `scripts/smoke.py` is the rig's own regression test: NODES heard,
  SABM answered, CTEXT received. If it passes and AXTerm misbehaves,
  the bug is AXTerm's.

## Chaos tools

The rig can be turned hostile — for testing how AXTerm behaves when the
channel, the neighbours, and the digipeaters are all against it.

```bash
# Hostile frames: malformed, truncated, oversized, wrong-PID, digi-path
# storms, KISS-escape abuse. A station hears garbage on a shared
# frequency; it must shrug it off.
python3 scripts/fuzz_channel.py --seconds 120 --rate 25

# A digipeater that misbehaves every documented way — pick your poison:
python3 scripts/bad_digipeater.py --alias RELAY --dupe 0.3       # stuck PTT
python3 scripts/bad_digipeater.py --alias RELAY --delay 300      # slow S&F
python3 scripts/bad_digipeater.py --alias RELAY --corrupt 0.2    # marginal copy
python3 scripts/bad_digipeater.py --alias RELAY --drop 0.4       # deaf on TX
python3 scripts/bad_digipeater.py --alias RELAY --reorder        # batching digi
python3 scripts/bad_digipeater.py --alias RELAY --no-hbit        # LOOP flooder

# Everything at once — rough channel + fuzzer + bad digi for two minutes.
scripts/chaos.sh
```

Connect AXTerm to a destination `VIA RELAY` while `bad_digipeater.py`
runs to see how retries survive duplicates, delays and corruption. Both
fuzzers are seeded and print their seed, so any fault reproduces.

These live tools are the sibling of the deterministic Swift fuzz suite
(`NodeSurfaceFuzzTests`, `AX25FuzzTests`, `AX25SessionFuzzTests`): the
Swift ones gate every build; these prove the whole app survives the
same abuse as a running process.
## The Xastir oracle (`--profile aprs`)

    docker compose --profile aprs up -d

Runs real **Xastir 2.1.8** as an APRS station on the shared channel, so
"AXTerm matches Xastir" is a claim a test can fail instead of a comment.
`XASTIR-1` answers queries and beacons; `XASTIR-2` never beacons, so an answer
cannot be confused with a posit that was coming anyway.

Two things about Xastir shape the container (`xastir/Dockerfile`):

- **No network-KISS device type.** `enum Device_Types` offers serial KISS,
  kernel AX.25 or AGWPE — nothing that dials a TCP KISS port. `socat` bridges a
  pty to the hub and Xastir opens it as `DEVICE_SERIAL_KISS_TNC` (type 10).
- **No headless mode.** It is X11/Motif, so it runs under Xvfb. Nothing ever
  looks at the frame buffer.

Three config traps, all of which fail silently and cost an hour each:

| Key | Trap |
| --- | --- |
| `DEVICE0_SPEED` | The **termios constant**, not a baud rate. `B9600` is `13`; writing `9600` fails `cfsetispeed` and reports only "Error opening interface 0 Hard Fail". The real error is behind `debug_level & 2` — set `XASTIR_DEBUG=2`. |
| `STATION_LAT` / `STATION_LONG` | Exactly `DDMM.mmmN` / `DDDMM.mmmW`. Anything else is silently replaced with `0000.000N`. |
| `STATION_MESSAGE_TYPE` | A **character**, used directly as the APRS data-type identifier. Writing `0` does not mean "type zero" — it makes the DTI the literal `'0'` and every posit malformed. Use `=`. |

Capture fixtures with `scripts/xastir_oracle.py`; see `Docs/APRSMessaging.md`.

## Over the air for real (`--profile rfnet`)

    docker compose --profile rfnet up -d
    # AXTerm / scripts/xastir_oracle.py -> 127.0.0.1:8013

The `aprs` profile puts Xastir on the kisshub, which *copies* frames between
clients — a channel model. `rfnet` removes the model: **one Direwolf per
station**, all of them playing into and listening to a single shared PulseAudio
null sink (`pulse/`). Every frame is AFSK-modulated at 1200 baud and
demodulated by a separate modem with its own DCD, TXDELAY and slot timing, and
two stations that key together garble each other in the audio domain.

    xastir-rf-a ──pty──▶ modem-a ─┐
    xastir-rf-b ──pty──▶ modem-b ─┼──▶ rf-ether (null sink + monitor)
    AXTerm :8013 ───────▶ modem-us ┘

Measured against the hub: identical protocol answers, 1.9–3.9 s instead of
~0.9 s. `XastirRFParityTests` pins both facts.

Traps found building it, all of which present as "it just sits there":

- **`docker compose restart` strands Xastir.** It opens its KISS pty once at
  startup and never reopens it, so a socat that exits and respawns hands it a
  fresh `/dev/pts` while Xastir holds the dead one — the station looks healthy
  and hears nothing. socat now uses `forever,retry` so the process, and the
  pty, survive a TNC restart.
- **Restart leaves state behind.** `/tmp/.X99-lock` makes Xvfb refuse, and
  `~/.xastir/xastir.pid` records pid 1 — which always exists in a container, so
  Xastir's "another instance is running" check can never pass again. The
  entrypoint clears both.
- **PulseAudio needs `module-native-protocol-unix` too.** With only the TCP
  module the modems connect fine but the container's own `pactl` cannot, so
  `set-default-sink` and the channel level fail "Connection refused" and the
  misconfiguration shows up only as an overdriven channel.
- **A null sink's monitor is full-scale**, so Direwolf reports `audio level =
  198` and warns. It decodes, but clipping makes collisions destructive for the
  wrong reason. `ETHER_VOLUME` attenuates the sink.

### The digipeater that never answers

`rfnet` includes `modem-digi` — a Direwolf with `DIGIPEAT` and no APRS
application behind it. It repeats WIDEn-N traffic with callsign substitution
and answers no query, ever, which is the most common station on a real APRS
channel and the one that makes "it hears me but won't answer" look like a bug.

One probe captures the whole thing: a `?APRSP` sent to the digipeater *via*
`WIDE1-1` comes back repeated by it — proof it received us — with no answer
attached. `RFDigipeaterEvidenceTests` runs those exact frames through AXTerm's
real `AX25.decodeFrame` and the live `APRSPingTracker` subscription, so the
"it hears us but did not answer" line is derived from bytes that were on a
channel rather than from a hand-built fixture.

Its counter-case matters as much: a beacon sent *direct* is never digipeated,
because there is no path to repeat — which is why a silent direct ping says
nothing about whether the station heard you.

### Proving AXTerm's own transmissions

`scripts/axterm_onair.py` transmits AXTerm's queries, ping, message and beacon
and records the channel's response; `AXTermOnAirTests` asserts AXTerm's
production builders emit those exact bytes. See `Docs/APRSMessaging.md`.

The beacon frames are the half that no reply can prove: nothing answers a
beacon. The script therefore also scrapes `modem-a`'s log for Direwolf's own
decode of each frame it sent, which is how the **compressed** beacon is held to
the fix it encoded — base-91 is where a wrong divisor still yields a
well-formed frame at the wrong place.

### Every APRS type, on the air (`scripts/aprs_zoo.py`)

    docker compose --profile rfnet up -d
    cd scripts
    python3 aprs_zoo.py --out ../../AXTermTests/Fixtures/aprs-zoo.json

Transmits one frame of every APRS type AXTerm can read — Mic-E, compressed and
uncompressed positions, object, item, telemetry, weather, status — through a
real modem, and records Direwolf's decode of each. `APRSZooTests` asserts
AXTerm's parsers agree.

These types are **parse-only** in AXTerm, so they can never be proven by a
round trip through it; something else has to put them on the channel and a
different implementation has to say what they mean.

Two traps, both found the hard way:

- **Match the decode by content, not by address.** Two probes share
  `SIMLA>APMI06` (telemetry and status), and keying the log scrape on
  `SRC>DEST` silently handed the status frame the telemetry decode. Each frame
  carries a `needle` — a fragment unique to it — for this reason.
- **Direwolf does not always leave a blank line** between a frame and a reply
  that arrives on its heels, so a decode block ends at the next `[` as well as
  at a blank line (`decode_block` in `xastir_oracle.py`).
