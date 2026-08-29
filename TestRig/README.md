# The AXTerm Test Rig

A real LinBPQ node on a simulated shared channel, in docker — so every
protocol feature can be exercised against the genuine article without
keying a transmitter. Nothing here ever touches RF; every callsign in
the rig is fictional and never leaves the compose network.

```
AXTerm (this Mac) ──┐
                    ├── kisshub :8010  ← the shared frequency
LinBPQ  BPQTST-7 ───┘      (every frame heard by every station)
(TSTNOD)   └─ telnet sysop console :8011
```

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
