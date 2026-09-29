# Connection Status Strip - Test Plan

## Overview
Connection Status Strip provides a compact, always-visible summary of current connection state above the message input bar. It displays essential connection metrics without duplicating SYS messages.

## Test Scenarios

### 1. Disconnected State
**Steps:**
1. Launch AXTerm
2. Navigate to Terminal view
3. Verify no active connection

**Expected Results:**
- Strip shows "Not connected • Select a station and Connect"
- Gray indicator circle
- Secondary typography for hint text
- Fixed height (32pt min) with stable layout
- Subtle background material with thin border

### 2. Connected - Direct AX.25 (no digipeaters)
**Steps:**
1. Enter destination callsign (e.g., "W0ARP-1")
2. Click Connect
3. Wait for connection establishment

**Expected Results:**
- Green indicator circle with remote callsign
- "AX.25" link mode badge in blue
- RTT value displayed after first packets exchanged (e.g., "RTT 2.1s")
- Window size K displayed (e.g., "K 4")
- No via path text
- No retry count initially

### 3. Connected - AX.25 with Digipeaters
**Steps:**
1. Enter destination with digi path (e.g., "W0ARP-1 v W0ARP-7 v W0ARP-3")
2. Click Connect
3. Wait for connection

**Expected Results:**
- Green indicator with remote callsign
- "AX.25" link mode badge
- "via W0ARP-7 → W0ARP-3" text in secondary
- RTT, K, retry metrics as above
- Two-line via display if configured via differs from received via

### 4. Connected - NET/ROM
**Steps:**
1. Switch to NET/ROM mode in connect bar
2. Enter NET/ROM destination
3. Connect via NET/ROM

**Expected Results:**
- Green indicator with remote callsign
- "NET/ROM" link mode badge in purple
- Route preview text from routing system
- RTT, K metrics if available
- NET/ROM specific path information

### 5. Connection with Retries
**Steps:**
1. Establish connection
2. Induce retries (network issues, interference, or test with packet loss)
3. Observe status strip updates

**Expected Results:**
- "Retries" metric appears when count > 0
- Number increments with each retransmission
- RTT may increase with backoff
- Connection remains green unless state changes

### 6. Connection State Transitions
**Steps:**
1. Connect to a station
2. Observe connected state
3. Disconnect
4. Observe disconnected state
5. Reconnect

**Expected Results:**
- Smooth transitions between states
- No layout jumping (fixed height maintained)
- Metrics reset appropriately on reconnect
- Material background and border consistent

## Visual Design Verification

### Typography & Colors
- Connected state: Primary weight for callsign, secondary for via paths
- Disconnected state: Secondary weight, tertiary for hint
- Metrics: Monospaced font, secondary labels, primary values
- Link badges: Colored backgrounds with appropriate contrast

### Layout Stability
- Height never changes (32pt min enforced)
- No content jumping during state changes
- Smooth animations for transitions
- Proper spacing and alignment maintained

### Dark Mode Compatibility
- Materials adapt to system appearance
- Text contrast remains readable
- Colors appropriate for dark backgrounds
- Border visibility maintained

## Edge Cases

### Empty Fields
- No metrics available = metric hidden (no placeholders)
- No via path = via section hidden
- Missing RTT = RTT metric hidden initially

### Rapid State Changes
- Quick connect/disconnect cycles
- No visual artifacts
- Proper cleanup of previous state

## Data Source Verification

### Live Updates
- RTT updates as new samples arrive
- Retry count increments immediately
- Window size reflects session config
- Via paths update with packet reception

### Session Integration
- Uses same session data as SessionStatusBadge
- Consistent with existing state management
- No duplicate state tracking

## Performance Impact

### Rendering
- Single strip component, minimal overhead
- Efficient @ViewBuilder usage
- No unnecessary recalculations

### Reactivity
- @Published properties trigger updates
- No polling loops
- Smooth 60fps animations

## Success Criteria

✅ **Functional Requirements**
- All connection states displayed correctly
- Metrics update in real-time
- No placeholder values shown
- Layout remains stable

✅ **Design Requirements**  
- Subtle, non-distracting appearance
- Works in dark/light mode
- Secondary typography used
- Material background with border

✅ **Integration Requirements**
- Uses existing session/view model data
- No duplicate state management
- Preserves SYS message flow
- No breaking changes

✅ **Performance Requirements**
- Minimal CPU/memory impact
- Smooth animations
- No layout thrashing
- Real-time updates

## Test Coverage Matrix

| Scenario | Expected | Pass/Fail | Notes |
|----------|-----------|------------|-------|
| Disconnected | Not connected + hint | | |
| Direct AX.25 | Callsign + AX.25 + metrics | | |
| AX.25 + Digi | Via path displayed | | |
| NET/ROM | Purple badge + route | | |
| With Retries | Retry count appears | | |
| State Change | Smooth transition | | |
| Dark Mode | Proper contrast | | |
| No Metrics | Metric section hidden | | |
| Rapid Changes | No visual artifacts | | |