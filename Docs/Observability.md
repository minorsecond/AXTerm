# Observability

How AXTerm reports to Sentry, what is deliberately withheld, and the rules new
code must follow. CLAUDE.md mandates breadcrumbs for packet ingest, decode
failures, routing decisions, graph rebuilds, layout cycles, and migrations —
this document is the map of where each lives.

## Architecture

Two entry paths converge on the Sentry SDK, and both pass through the same
governors:

```
TxLog (transmission subsystem, nonisolated statics)
  └─ hops to @MainActor SentryManager
Telemetry (analytics/routing facade, nonisolated)
  └─ SentryTelemetryBackend (direct SDK access)

Both apply, from AXTerm/Observability/Sentry/TelemetryGovernor.swift:
  • SharedBreadcrumbBudget  — per-category flood control
  • TelemetryContentRedactor — privacy gating
SentryManager additionally applies:
  • EventThrottle            — identical-event collapse
```

### Breadcrumbs vs. events

Breadcrumbs sit in a ring buffer (`maxBreadcrumbs = 300`) and only transmit
when some **event** is captured. Anything that must be diagnosable on its own
therefore needs an event, not a breadcrumb:

- `TxLog.error(…)` → captured event (all builds)
- `TxLog.dataLoss(…)` → captured event — REQUIRED wherever received user data
  is permanently discarded (e.g. the receive-gap flush, which resets the retry
  counter and thereby suppresses the link-failure event that would otherwise
  have shipped the surrounding crumbs)
- `TxLog.invariantViolation(…)` → throttled event in ALL builds, followed by a
  debug-only `assertionFailure`. Never write a bare `assert` for protocol
  state: it traps without reporting in debug and compiles out in release.
- `TxLog.debug/info/warning(…)` → breadcrumb only

### Flood control (`BreadcrumbBudget`)

Per category, per window (30 s): warnings get 60, info/debug get 20, errors
are never dropped. Warning and info budgets are separate so a debug flood
cannot starve warnings. When a window rolls over after drops, one summary
crumb reports the suppressed count — silence is never ambiguous.

Rationale: a field capture measured ~7 crumbs/s on an ordinary session; the
SDK's default 100-crumb buffer held ~14 s of history, evicting the protocol
sequence a failure event needs.

### Event throttling (`EventThrottle`)

`SentryManager.captureThrottled(key:…)` ships the first occurrence
immediately, suppresses identical repeats for 60 s, and attaches the
suppressed count to the next one. Used for decode failures (keyed per reason),
invariant violations, AXDP/compression errors — anything a hostile byte
stream can trigger per-frame.

## Privacy

`sendDefaultPii = false`. Two independent user settings gate what leaves the
machine, both off by default:

- **Send packet contents** (`sentrySendPacketContents`): unless enabled,
  `TelemetryContentRedactor` replaces content-bearing values in every
  breadcrumb and event extra — keys like `preview`, `text`, `hex`, `ascii`,
  `payload`, and any key ending in `Hex`/`Ascii`/`Preview`/`Text` — with
  `[content withheld]`. Metadata (callsigns, sequence numbers, sizes, timing)
  always passes; that is what remote diagnosis needs. Third-party traffic
  relayed through a BBS is other people's mail and must never ship as a side
  effect of diagnostics. The setting is mirrored into `TelemetryPrivacy.shared`
  so nonisolated paths honor it without a main-actor hop.
- **Send connection details** (`sentrySendConnectionDetails`): gates KISS
  host/port tags.

`beforeSend` additionally redacts credential-shaped keys (password, token, …).

## Where the mandated areas are instrumented

- **Packet ingest**: `PacketEngine.handleIncomingPacket` (`packets.insert`),
  sampled decode-success crumb, per-frame `TxLog` crumbs — all budgeted.
- **Decode failures**: KISS reject paths log warnings with reasons
  (`KISSAX25Decoder`); AX.25 decode failure ships ONE throttled event with a
  differentiated reason from `AX25.decodeFailureReason`.
- **Routing decisions**: `netrom.routing` crumbs — next-hop selected/switched
  (`NetRomRouter.bestRouteTo`), new route stored (`storeRoute`), stale purges,
  and mode changes (`NetRomIntegration.setMode`).
- **Graph rebuilds**: `graph.build.started/finished` in
  `AnalyticsDashboardViewModel`, rate-limited.
- **Layout cycles**: `analytics.graph.layout` crumbs (cache hit / computed,
  with reason and duration) in `prepareLayout`; dropped-node layouts capture
  an event in all builds. (`AnalyticsViewModel` in PacketEngine.swift carries
  older layout telemetry but is never instantiated — do not extend it.)
- **Migrations**: `DatabaseManager.registerReportedMigration` wraps every
  migration with start/success/failure breadcrumbs plus a captured event on
  failure naming the migration and version. The database-open success crumb
  is emitted only after migrations complete.

## Protocol failure coverage

Captured as events in all builds: N2 link failure, DM refusals, FRMR
(inbound FRMR is dispatched via `AX25SessionManager.handleInboundFRMR`),
send/transport failures, KISS link failure on every transport (TCP, BLE,
serial — `handleLinkStateChange .failed`), receive-gap data loss, invariant
violations. Visible as warning crumbs: T1 timeouts, RNR busy enter/clear,
state transitions into `.error`, DM-for-unknown-session desyncs.

## Rules for new code

1. Discarding received data → `TxLog.dataLoss`, never just a log line.
2. Protocol-state sanity checks → `TxLog.invariantViolation` + debug
   `assertionFailure`, never a bare `assert`.
3. `catch` blocks must report (`Telemetry.capture` / `capturePersistenceFailure`)
   or carry a comment explaining why swallowing is correct.
4. Never put over-the-air content in a telemetry field whose key isn't in the
   redactor's content list — when in doubt, name the key `preview` or `text`
   so it IS redacted.
5. High-frequency events go through `captureThrottled`, keyed by cause.
