# Connect Bar v2 (AX.25 + NET/ROM)

## Explicit connect types
- `AX.25`: L2 connected-mode SABM/UA session direct to `To` callsign.
- `AX.25 via Digi`: L2 connected-mode SABM/UA with ordered digipeater list.
- `NET/ROM`: L3-style intent with route preview + optional forced next hop.

The UI keeps AX.25 digipeater lists and NET/ROM routing controls separate.

## ConnectIntent mapping
`ConnectIntent` is the single connect execution payload:
- `kind`: `ax25Direct`, `ax25ViaDigis([CallsignSSID])`, `netrom(nextHopOverride: CallsignSSID?)`
- `to`: destination callsign/node
- `sourceContext`: routes / neighbors / stations / terminal
- `suggestedRoutePreview`: read-only route text for NET/ROM mode
- `validationErrors`: inline validation failures

Execution behavior:
- `ax25Direct`: opens/focuses session, sends SABM to `to`.
- `ax25ViaDigis`: opens/focuses session, sends SABM to `to` with ordered digipeater path.
- `netrom`: current stack has no native NET/ROM transport connect primitive; AXTerm falls back to opening an AX.25 connected session to selected/derived next hop and posts a terminal note documenting the fallback.

## Initiation defaults
- Route row action defaults to `NET/ROM`.
- Neighbor and Station initiation defaults to `AX.25`.
- Last selected mode is persisted by context.

## Navigation/session behavior
For connected-session requests, AXTerm immediately switches to Terminal, creates/focuses the target session state, and keeps failures/status updates visible in that session context.
