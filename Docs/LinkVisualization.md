# Link Visualization

Live, evidence-based visualizations of connected-mode AX.25 links and channel
activity. Everything shown is derived from real protocol events — no
simulation, no decoration. This document covers the event pipeline, the
aggregation math, and each view.

## Data flow

```
AX25SessionManager ──onLinkVizEvent──▶ LinkVizMonitor ──▶ LinkSessionViz (per peer)
                                                            ├─ WindowRingView
                                                            ├─ RTTChartView
                                                            ├─ WindowSawtoothView
                                                            ├─ ThroughputChartView
                                                            └─ BlockCadenceStrip

PacketEngine (every TX/RX frame) ──▶ ChannelActivityMonitor ──▶ ChannelAirtimeLanesView
                                 └──▶ GraphPulseBus ──▶ network graph edge pulses
```

All types live in `AXTerm/Transmission/LinkVizMonitor.swift` (models) and
`AXTerm/UI/LinkVizViews.swift` (views). The B2F replay diagram is
`AXTerm/Winlink/UI/WinlinkExchangeReplayView.swift`.

## Events (`LinkVizEvent`)

Emitted by `AX25SessionManager` via the `onLinkVizEvent` callback, wired to
`SessionCoordinator.linkVizMonitor` at startup. Deliberately tiny — the
session manager is on the hot path.

| Event | Emitted when | Source |
|---|---|---|
| `.snapshot` | Session state dump (inbound I/RR, T1 timeout, REJ, RNR) | `debugDumpSessionState` |
| `.inboundIFrame` | Any inbound I-frame, before dup/order checks | I-frame ingest |
| `.delivered` | Payload bytes delivered in order to the application | `.deliverData` action |
| `.rejSent` | We ask the peer to retransmit from N(R) | `.sendREJ` action |
| `.retransmit` | We retransmit one of our own I-frames | retransmission path |

`LinkWindowSnapshot` carries V(S)/V(A)/V(R), outstanding count, window size K,
retry count, the send-buffer sequence numbers, and the live RTO/SRTT/RTTVAR
from the session timers.

## Aggregation (`LinkSessionViz`)

One instance per peer (keyed by uppercased callsign), bounded memory:

- **RTT history** (cap 400): one sample per snapshot whose SRTT or RTO
  changed. Deduplicated so idle links don't fill the buffer.
- **Window history** (cap 800): outstanding vs. K over time. A snapshot with
  context `T1-timeout` marks a `t1` loss event; a `.rejSent` marks `rej`.
- **Deliveries** (cap 900): each in-order delivery with byte count — feeds the
  block cadence strip.
- **Throughput** (cap 900 = 15 min of 1 s buckets): second-aligned buckets of
  `rawBytes` (all inbound I payload, retransmitted copies included) vs.
  `deliveredBytes` (goodput). The gap between the two IS the retransmit
  overhead: `receiveOverheadFraction = 1 − delivered/raw`.

`resetTransferCounters()` zeroes the per-transfer counters (raw/delivered
bytes, REJ/T1/retransmit counts, deliveries, throughput) but keeps RTT and
window history — link characteristics outlive one transfer. The Winlink
ladder calls it once per rung before `runExchange`.

## Views

- **`WindowRingView`** — the modulo-8 sequence space as a ring. Blue slots:
  our I-frames awaiting ACK (send-buffer contents, V(A)→V(S)); green ring:
  V(R), the next frame expected from the peer. Center legend shows K and the
  outstanding count.
- **`RTTChartView`** — SRTT line with ±RTTVAR band, RTO as a dashed ceiling.
  T1 fires when an ACK takes longer than the ceiling.
- **`WindowSawtoothView`** — outstanding frames vs. configured K (step
  lines), REJ (orange) and T1 (red) loss events as points. The AIMD
  controller's personality made visible.
- **`ThroughputChartView`** — goodput (green) under raw channel bytes
  (orange); the orange-only area is bytes burned on retransmitted copies.
- **`BlockCadenceStrip`** — each delivered block as a grid cell, filling
  left-to-right. Green: on pace; orange: interarrival gap > 3× running
  median (stall/retransmit cycle); blue: newest; gray: expected but not yet
  received (projected from the transfer size when the runner knows it).
- **`ChannelAirtimeLanesView`** — one lane per heard station (busiest first),
  each frame a tick whose width is estimated airtime, plus a channel
  utilization percentage. Lives in the Analytics dashboard.
- **`DirectionalHealthView`** — df and dr side by side with the frame counts
  each is derived from, and the resulting ETX. A single link-quality number
  hides an asymmetric path, which on packet is the case that matters: during
  a download we barely transmit, so a forward-only reading calls a
  struggling link perfect. See RoutingMetrics.md § "Session-scoped ETX".
- **`SessionBudgetView`** — elapsed session time against the cap this
  gateway has been observed to enforce, and what that means for the transfer
  in progress. The arithmetic lives in `SessionBudget` so it can be tested
  without a view.
- **`ResumeAwareProgressBar`** — teal for bytes carried over from an
  interrupted session, accent for bytes moved now.

Where they appear:

- **Adaptive toolbar popover** (`AdaptiveToolbarControl`): segmented
  ETX / RTT / Window charts. RTT and Window describe the selected adaptive
  session's link, falling back to the most recently active link.
- **Winlink exchange console** (`WinlinkExchangeConsoleView`): a
  Transcript / Activity toggle. Activity shows the block strip, throughput,
  and window ring for the gateway link, with a header line of delivered
  bytes, retransmit-overhead %, and REJ count.
- **Winlink exchange dashboard** (`WinlinkExchangeDashboardView`): the
  full-page view, opened from the console's chart button and closed with
  Done. Optional by design — the console strip answers "is it moving?", the
  dashboard answers the questions you get while watching a slow transfer:
  which direction is losing frames, whether the gateway will cut the session
  before the message lands, and what the controller is doing about it.
  Panels: transfer (resume-aware), link health, session budget, throughput,
  frames in flight, RTT, block arrivals, adaptive parameters. Ticks once a
  second so a stalled link keeps updating instead of freezing on the last
  packet. Tests: `ExchangeDashboardTests`.
- **Analytics dashboard**: the channel activity lanes card.

## Airtime estimation

`ChannelActivityMonitor` estimates per-frame airtime from frame length at the
configured baud rate:

```
airtime = (frameBytes + 6) * 8 * 1.05 / baud
```

+6 bytes approximates HDLC flags/CRC; 1.05 approximates bit-stuffing. Honest
without a bit-exact model. Utilization = busy seconds / window (10 min),
clamped to 1. TX frames are recorded in `PacketEngine.send`, RX frames at
decode. This is UI/etiquette information only — never routing input.

## Graph pulses

`GraphPulseBus` is a single-callback bus (not Combine — the packet hot path
stays allocation-free). `PacketEngine` pulses the first RF hop of every
decoded frame (source → first digipeater, else destination). The Metal graph
coordinator subscribes on attach, resolves callsigns through grouped SSIDs to
node ids, and briefly (1.2 s) overdraws the matching edge in the accent
color, fading quadratically. Pulses keep the otherwise-paused MTKView drawing
until they expire; at most 64 edges pulse concurrently. Pulses only ever
highlight edges that exist in the graph model — the graph stays routing
intelligence, the pulse is just its heartbeat.

## B2F session replay

`WinlinkExchangeReplayView` renders a finished exchange's transcript as a
sequence diagram: sent lines as rightward arrows, received as leftward,
events as centered capsules. Runs of binary-block summaries (`‹N bytes…›`)
collapse into one thick arrow labeled with block count and total size, so a
40 KB transfer reads as one stroke instead of hundreds of rows. Opened from
the clock button in the exchange console header.

## Tests

`AXTermTests/Unit/Transmission/LinkVizMonitorTests.swift` pins the
aggregation math (overhead accounting, throughput bucketing, loss markers,
RTT dedup, caps, reset semantics, airtime math, lane ordering, trimming).
`AXTermTests/Unit/Winlink/WinlinkExchangeReplayTests.swift` pins the binary
block-summary parser against the exact strings the console emits.

Note: these are `@MainActor` ObservableObjects; test methods must be `async`
(the project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and
synchronous dealloc of an isolated object in a sync test aborts the process).
