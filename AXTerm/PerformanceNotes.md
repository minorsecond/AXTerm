# Performance Findings (March 2026)

## Root cause
- Packet table updates were writing SwiftUI bindings during `NSViewRepresentable` updates and scroll callbacks. That synchronous feedback loop (scroll -> binding write -> updateNSView -> scroll) could peg CPU when switching tabs, especially after Analytics kicked off work. The table also rebuilt row models + column sizing on every packet, increasing update pressure.
- Analytics graph layout tasks and aggregation work could remain active even after the Analytics view disappeared, keeping background work alive and amplifying main-thread updates when returning to Packets.

## Fix summary
- Packet table updates are now coalesced and guarded against re-entrant scroll/binding updates. Scroll state bindings publish on the next run loop (throttled), and programmatic scrolls ignore scroll callbacks to avoid feedback loops.
- Table row updates only insert/remove when packets append at the top or truncate at the bottom, falling back to reloads only when needed. Column sizing is throttled.
- Analytics view lifecycle now activates/deactivates aggregation/graph work and cancels layout tasks on disappear to prevent background loops.

## Validation notes
- Use Instruments + Points of Interest (or debug logs) to verify no hot loop in `PacketNSTableView` after switching Analytics → Packets.
- Confirm Analytics layout ticks stop after leaving the Analytics screen.
