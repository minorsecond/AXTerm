# AXTerm Connect Bar v3 Behavioral Spec

## 1) Final Behavioral Recap

AXTerm bottom bar is now constrained to three layouts only:

1. `DisconnectedDraft`
2. `ConnectedSession`
3. `BroadcastComposer`

No hybrid layout is valid. Draft editing is only available while disconnected. Connected state is session-first and read-only. Broadcast is unproto composer-only.

## 2) State Model

### `ConnectBarState`

- `disconnectedDraft(ConnectDraft)`
- `connecting(ConnectDraft)`
- `connectedSession(SessionInfo)`
- `disconnecting(SessionInfo)`
- `broadcastComposer(BroadcastComposerState)`
- `failed(ConnectDraft, ConnectFailure)`

### `ConnectDraft`

- `sourceContext`: `ConnectSourceContext`
- `destination`: `String`
- `transport`: `ConnectTransportDraft`

`ConnectTransportDraft` is a closed enum that preserves protocol semantics:

- `ax25(AX25DraftOptions)`
  - `.direct`
  - `.viaDigipeaters([String])`
- `netrom(NetRomDraftOptions)`
  - optional forced next hop
  - optional route preview

### `SessionInfo`

- `sourceContext`
- `sourceCall`
- `destination`
- `transport`: `SessionTransport`
- `connectedAt`

`SessionTransport`:

- `ax25(via: [String])`
- `netrom(nextHop: String?, forced: Bool)`

### `AdaptiveTelemetry`

- `k`
- `p`
- `n2`
- `rtoSeconds`
- `qualityLabel`

Compact surface label: `Kx Py N2 z`.

## 3) Bottom Bar View Hierarchy

- `BottomBarHost`
  - Switches strictly on `ConnectBarState`
  - Renders one of:
    - `DisconnectedDraftBar`
    - `ConnectedSessionStrip`
    - `BroadcastComposerBar`

### `DisconnectedDraftBar`

- Destination field (hero control)
- Protocol selector
- Advanced button (popover trigger only)
- Connect action
- Summary line

### `ConnectedSessionStrip`

- Session summary text
- Connection status indicator
- Disconnect action
- Adaptive telemetry compact chip

### `BroadcastComposerBar`

- Message composer
- Send action
- Optional unproto path chip
- No destination/protocol/connect controls

## 4) Transition Model

Authoritative transitions:

- `DisconnectedDraft -> Connecting` on connect request
- `Connecting -> ConnectedSession` on session established
- `Connecting -> Failed` on connect failure
- `ConnectedSession -> Disconnecting` on disconnect request
- `Disconnecting -> DisconnectedDraft` on disconnect completion
- `* -> BroadcastComposer` on broadcast mode selection
- `BroadcastComposer -> DisconnectedDraft` on connect mode selection

Illegal mixed UI states are prevented by deriving view from `ConnectBarState` only.

## 5) Sidebar -> ViewModel Flow

Single-click station:

1. Build `SidebarStationSelection` with:
   - station callsign
   - context
   - last-used mode for station (if known)
   - route-availability flag
2. Run mode selection policy:
   - last-used mode
   - else NET/ROM if route exists
   - else AX.25 direct
3. Emit `sidebarSelection(..., .prefill)`
4. Reducer creates `ConnectDraft` and publishes `disconnectedDraft`

Double-click station:

- Same draft prefill, then emit `.connect` action
- Reducer transitions to `connecting(draft)`

Context menu actions produce explicit events (`connect`, `connect via AX.25`, `connect via NET/ROM`) that route through the same reducer path.

## 6) Structural Protocol-Semantics Enforcement

- NET/ROM draft cannot represent manual multi-hop digi chain (no equivalent field).
- AX.25 draft can represent direct or ordered digi path only.
- Broadcast state carries unproto settings only; no destination/protocol fields exist.
- Session summary transport uses sealed enum (`SessionTransport`) to avoid mixed protocol rendering.

## 7) Multi-Session Extensibility Notes

Current model assumes one active foreground session strip. For future multi-session:

- Keep `ConnectBarState` as foreground view state.
- Add `SessionRegistry` with `[SessionInfo]` plus foreground `sessionID`.
- `connectedSession` / `disconnecting` payload becomes `sessionID` + lookup.
- Sidebar highlight supports multiple connected rows with one foreground accent.
- Bottom strip controls foreground session; switcher can be introduced without changing protocol draft model.
