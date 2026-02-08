# CLAUDE.md — AXTerm Canonical Development Guide

This document is the **authoritative specification** for how AXTerm must behave.
Any AI assistant or human contributor MUST follow this document exactly.

AXTerm is not a demo, toy, or visualization-only app.
It is a **protocol-correct packet terminal, NET/ROM node, and BBS system**
with first-class observability, routing intelligence, and macOS-native UX.

If behavior is ambiguous, default to:

**Protocol correctness → determinism → observability → performance → UI polish**

---

## 1. Project Identity

**AXTerm** is a macOS application for monitoring, analyzing, routing, and
interacting with packet radio networks.

Supported and planned capabilities include:
- AX.25 decoding and connected-mode operation
- NET/ROM routing and circuits
- Modern inferred routing (df/dr/ETX/dups/decay)
- Packet terminal sessions
- Mailbox / BBS services
- Network graph–driven routing intelligence

AXTerm is explicitly **not APRS-only** and **not passive-only**.

---

## 2. Technology Stack

### Platform
- macOS 13+
- Swift 5+
- SwiftUI
- Metal (for graph rendering)
- Combine (no RxSwift)

### Persistence
- SQLite via **GRDB.swift 6.29.3**
- WAL mode enabled
- Snapshot-safe reads
- Explicit transaction boundaries

### Observability
- **Sentry Cocoa 9.3.0**
- Breadcrumbs for packet ingest, decode failures, routing decisions, graph rebuilds,
  layout cycles, and migrations

---

## 3. Core Data Flow

```
RF / TCP / Replay
        ↓
KISS Frame Decoder
        ↓
AX.25 Frame Decoder
        ↓
Protocol Classifier (I / S / U)
        ↓
Routing Inference Engine
        ↓
PacketEngine
        ↓
Persistence (SQLite)
        ↓
SwiftUI Views / Metal Graph
```

---

## 4. Protocol Handling Rules

### AX.25
- Control field MUST be decoded and stored
- I, S, and U frames MUST be classified
- Sequence numbers MUST be tracked
- ACKs and retries MUST be identified

### KISS
- Escape handling MUST be correct
- Partial frames MUST be buffered safely
- Malformed frames MUST be logged, not dropped silently

---

## 5. Session Model

AXTerm SHALL implement a **true session abstraction**.

Session types:
- AX.25 connected-mode
- NET/ROM circuits
- BBS mailbox sessions
- Forwarding sessions

Each session MUST include:
- stable session ID
- local and remote identity
- protocol
- open / last activity / close timestamps
- retry and timeout state
- routing context

Sessions MUST survive UI reloads and app restarts.

---

## 6. Packet Terminal Behavior

AXTerm SHALL function as an **interactive packet terminal**, not a log viewer.

Terminal requirements:
- line-oriented and raw modes
- echo handling
- session-aware input/output
- deterministic replay
- no reordering of received bytes

---

## 7. Mailbox & BBS System

AXTerm SHALL include a **first-class mailbox and BBS system**.

Message types:
- Private mail
- Bulletins
- System notices
- Routed third-party mail

Messages are append-only and immutable after delivery.

---

## 8. Routing Inference Metrics (Neighbors / Routes / Link Quality)

AXTerm uses **modern inferred routing metrics** derived from observed traffic.

All metrics MUST be:
- evidence-based (packet-derived)
- time-windowed
- decay-aware
- explainable via tooltips and drill-down

### df / dr (Directional Delivery Probabilities)

- **df**: probability of successful forward delivery
- **dr**: probability of successful reverse delivery

Updated using EWMA:

```
df_t = (1-λ) * df_{t-1} + λ * s_fwd
dr_t = (1-λ) * dr_{t-1} + λ * s_rev
```

Where:

```
λ = 1 - exp(-Δt / H)
```

Defaults:
- H_neighbors = 30 minutes
- H_routes    = 2 hours

---

### ETX (Expected Transmissions)

```
ETX = 1 / (max(df,0.05) * max(dr,0.05))
ETX clamped to [1.0, 20.0]
```

---

### Duplicate Ratio (dups)

```
dups = duplicate_packets / max(total_packets, 1)
```

Duplicates are detected via packet fingerprinting within a short interval.

---

### Recency & Decay

```
recency = exp(-Δt / τ)
decay%  = 100 * (1 - recency)
```

Defaults:
- τ_neighbors = 45 minutes
- τ_routes    = 3 hours

---

### Composite Quality Score (0–255)

```
g_etx  = 1 / ETX
g_dups = 1 - dups

goodness =
  (0.30 * df) +
  (0.30 * dr) +
  (0.30 * g_etx) +
  (0.10 * g_dups)

goodness = goodness * recency
quality  = round(255 * clamp(goodness, 0, 1))
```

This score is **for UI ranking only**; routing logic MUST use raw metrics.

---

## 9. Route Inference (Destination → Next Hop)

Routes are inferred from:
- via paths
- connected-mode sessions
- repeated delivery evidence

Hop penalty:

```
hopPenalty = 1 / (1 + hops^2)
routeGoodness = neighborGoodness * hopPenalty
```

Highest-quality route wins with deterministic tie-breaking.

---

## 10. Network Graph Semantics

The network graph is **routing intelligence**, not decoration.

Edges encode:
- df / dr
- ETX
- dups
- recency
- traffic volume
- directionality

Layout MUST be deterministic and stable.

---

## 11. UI / UX Requirements (Non-Negotiable)

AXTerm MUST follow **Apple Human Interface Guidelines**.

### Mandatory Tooltips

Every advanced metric MUST have a tooltip explaining derivation.

Example tooltip for Quality:

> **Quality: 239 (93%)**  
> df=0.97, dr=0.96  
> ETX=1.07  
> dups=0.03  
> recency=0.91  
> quality = weighted composite × recency  
> (See Docs/RoutingMetrics.md)

Tooltips MUST explain **why the value is what it is**, not just define terms.

---

## 12. Performance Rules

- No unbounded view-driven loops
- All layout tasks cancellable
- GPU-backed graph rendering
- Batched DB writes

---

## 13. Testing Requirements

- Unit tests for decoding and routing math
- Property tests for malformed and replayed packets
- Determinism tests for graph layout and route choice

No feature is complete without tests.

---

## 14. Documentation Discipline

Every major subsystem MUST have a document in `Docs/`.
Docs and code must agree; if not, code is wrong.

---

## 15. AI Contributor Rules

AI MUST:
- preserve protocol correctness
- avoid inventing semantics
- prefer explicit state machines
- halt if uncertain

SEE AXTERM-TRANSMISSION-SPEC.md for any and all work regarding the AXDP extension, or anything regarding transmitting/receiving packets. 

---

AXTerm aims to be the **packet terminal, BBS, and routing laboratory**
that packet radio never had.

Anything less is a regression.
