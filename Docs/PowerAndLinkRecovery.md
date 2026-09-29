# Power, Sleep and Getting Back On The Air

What AXTerm asks the operating system for, what happens to the radio links
when it does not get it, and how a link that goes down comes back.

`AXTerm/Platform/KeepAwake.swift`, `AXTerm/Platform/SystemPowerMonitor.swift`,
`AXTerm/Radio/LinkOutageWatch.swift`, `AXTerm/Transmission/KISSLinkNetwork.swift`.

## The night this came from

On 2026-09-18 the station was left running overnight with two radios: an
IC-705 over its own Wi-Fi, and Direwolf on a Raspberry Pi over TCP. In the
morning it had been off the air since ten to eight the previous evening.

The Mac never slept — other processes held system sleep off all night. What
happened was smaller and harder to see:

```
19:50:07  Display is turned off          (pmset)
19:50:07  IcomLAN connected → failed     (0.3s later)
19:50:07  Frame transmitted              (the last one, all night)
~20:20    tcp_input flags=[R] → KISS link failed, NWError 57
03:54:45  Display is turned on           (pmset)
03:55:24  IcomLAN connecting → connected
```

With no visible window and no user input, macOS put the app into App Nap and
coalesced its timers into roughly half-hour batches. The IC-705's LAN session
stopped getting its keepalives and the radio dropped the client. The KISS
socket stopped being read promptly and the far end reset it. Four times that
evening the display came on and the 705 reconnected within a second; four
times it went off and the link died. That correlation is what made the cause
legible at all.

Then it got worse in a way worth naming separately. `KISSLinkNetwork` had no
reconnect, so the Direwolf link never came back — for eight hours, with the
app running and the network up. Meanwhile the NET/ROM broadcast and station ID
timers kept firing into dead links, and each failure was reported at error
level: thirty-two transport reports, twenty session reports, every one of them
describing the symptom, none of them describing the outage.

## Two holds, only one of them a choice

`ProcessInfo.beginActivity` offers two different things and AXTerm asks for
them separately.

| | What it does | Who decides |
|---|---|---|
| `.userInitiatedAllowingIdleSystemSleep` | Defeats App Nap. Timers keep their schedule. Does not keep the machine awake. | Nobody. Held whenever a link is open. |
| `.userInitiated` | The above, plus holds off idle system sleep. | The operator, via `KeepAwakePolicy`. |

Staying scheduled is not offered as a preference because there is no case for
the other answer. An app holding open radio links should not be throttled, it
costs the operator nothing, and it does not touch their power settings.
Holding off sleep does cost battery, so that one is theirs.

Neither touches display sleep. There is no reason to hold a screen on to run a
node and AXTerm deliberately does not.

`KeepAwakeController.hold(policy:isConnected:isTransferring:isListening:)` is
the whole decision, pure and tested as a table.

### What it cannot do

Closing a laptop lid sleeps the Mac. `PreventUserIdleSystemSleep` prevents
*idle* sleep; so does `PreventSystemSleep`; neither overrides a lid close,
because macOS treats that as an instruction from the operator. Clamshell mode
needs an external display, power and an input device. There is no supported
API for refusing, and the settings text says so rather than implying a promise
the app cannot keep.

## Going to sleep on purpose

Sleep now gets the same teardown quitting does. For a long time it got half:
`ContentView` shut the BBS down on `willSleepNotification` and nothing else, so
a mailbox user was told the station was leaving while anyone in a
connected-mode session or a NET/ROM circuit watched it stop answering and had
to burn T1 × N2 finding out why.

`AXTermAppDelegate.prepareForSleep()`, in order:

1. `SessionCoordinator.prepareForTermination()` — a DISC to every live session,
   through `LinkTeardownPolicy`, which sends one only where the far side
   provably holds state.
2. A console line saying what was released.
3. A short grace, then `RadioManager.suspendAll()` — every link down
   deliberately, and still wanted. The grace is the same 0.4s the quit path
   takes and exists for the same reason: `prepareForTermination` hands the
   DISCs to the link, and tearing the socket down in the next statement would
   cancel them before a byte left.
4. `KeepAwakeController.release()`.

In the delegate rather than in `ContentView`, for the same reason the
keep-awake controller is shared: with the menu bar icon on, closing the window
tears the view down while the station keeps running, and the machine could
then sleep with live sessions on the air and nobody left to release them. The
view keeps what is genuinely its own — the mailbox goodbye, the service address
table, and the keep-awake indicator.

The DISCs are transmitted and not waited on. A UA needs a round trip over a
radio link and there is no waiting for one on a machine that is about to stop
executing; macOS's window on `willSleepNotification` is short and not
guaranteed. A lost DISC still leaves the peer to time out, and nothing here can
fix that. Best-effort is a large improvement over vanishing and it is the
ceiling.

`suspend()` is distinct from `close()` throughout, and the distinction is the
operator's intent. `close()` means they changed their mind, clears `wantsOpen`,
and nothing brings the link back by itself. `suspend()` means the machine is
leaving; the link stays wanted and `resume()` is coming.

## Coming back

On `didWakeNotification`:

- The outage is stated as a fact — `Off the air 19:50–03:54 (8h 4m) — this
  machine was asleep.` — rather than left to be inferred from a hole in the
  timestamps.
- `RadioManager.resumeAll()` reopens every wanted link with the backoff
  cleared. Making the station serve an exponential delay accrued while its
  operator's laptop was shut is how a node stays off the air long after the Mac
  is awake.
- `LinkOutageWatch.reset` restarts the outage clocks without reporting. A
  sleeping machine has every link down by definition, and counting that time
  would hand the operator an alert about their own lid.
- `SessionCoordinator.announceAfterWake()` arms one NODES broadcast thirty
  seconds out, reusing the warm-up shot the launch path already had. Our
  neighbours' routes to this station aged while it was away and the steady
  cadence can be an hour. Thirty seconds rather than the launch path's ninety
  because a resumed link reopens with no backoff to serve, but still a delay,
  because a Mac that has just woken has not finished re-associating to Wi-Fi.

There is no `suspended` case in `KISSLinkState`. The distinction that matters
is intent, and `wantsOpen` already carries it: `close()` clears it and nothing
brings the link back, `suspend()` leaves it set and `resume()` is coming. A
fourth state would have rippled through every switch, the status surfaces and
the persisted link records to say something two existing pieces already say.

## Reconnect on the TCP link

`KISSLinkNetwork` was the only transport that gave up. Serial and Bluetooth
have had auto-reconnect and a profile flag since they were written.

The policy is `ModemRadioLink`'s, deliberately reused rather than reinvented:
double from one second, cap at thirty, add up to half a second of jitter so two
radios on one Direwolf do not retry in lockstep forever, and clamp the attempt
counter rather than giving up at it. The backoff clears only once a connection
has *held* for `stableConnectionSeconds`; Direwolf accepts a TCP connection
before it knows whether it can serve one, so a socket that opens and dies
inside a few seconds is a failure wearing a success's clothes.

Two failures are not retried, because they are settled rather than transient:
port zero, and a host this process may not reach. Port zero has to be rejected
by hand — `NWEndpoint.Port(rawValue: 0)` succeeds and means "any", which for an
outbound connection is not a port, and left alone it becomes a connection that
fails forever with a thirty-second delay in it.

A dropped connection has its `stateUpdateHandler` cleared before it is
cancelled. `cancel()` delivers `.cancelled` asynchronously, and a late report
from a dead connection landing on a live one puts a freshly reopened link back
to `.disconnected` — which is exactly what a resume after sleep looked like
before this was fixed.

`RadioProfile.tcpAutoReconnect` turns it off, defaulting on, matching
`serialAutoReconnect` and `bleAutoReconnect`. Like those two it is a profile
field with no settings control, because the answer is almost always yes.

## Saying the right thing

Three rules, all of them reactions to the same night.

**A drop over sleep is not an error.** `SystemPowerMonitor.cause(forDropAt:)`
classifies it, and `PacketEngine` says "went down while this machine was asleep,
reconnecting" instead of `Connection failed: Socket is not connected (NWError
57)`. Nothing is reported, and `LinkSession` keeps it out of `lastError` so the
connection banner stays clear too. Reading a POSIX error number should not be
how an operator learns they closed their laptop.

**A send that fails because the link is down is a breadcrumb.** `SendFailure
.isLinkDown` tells it from a send that failed on a live link, which stays an
error. A node beaconing every half hour into a dead socket will keep
discovering the socket is dead; that is a consequence, and it had been burying
its own cause.

**A link that stays down is the event.** `LinkOutageWatch` reports once per
outage, after ten minutes — long enough to sit out an ordinary reconnect, short
enough to notice inside one NET/ROM broadcast interval. That night it would
have produced one accurate alert at about 20:30 in place of fifty-two
misleading ones and an eight-hour silence.

## Tests

`AXTermTests/Unit/Station/KeepAwakeTests.swift` — the policy table, the split
between the two holds, the platform question this file used to answer the other
way, and the controller's incremental updates: a link coming up being enough on
its own, a policy change re-applying, and release dropping everything.

`AXTermTests/Unit/Station/SystemPowerMonitorTests.swift` — the classification
against plain dates: asleep, just woken, long since woken, and a drop that
happened before the sleep and is therefore still a fault.

`AXTermTests/Unit/Radio/LinkOutageWatchTests.swift` — reported once and not
sixteen times, a recovery arming the next one, retrying not restarting the
clock, and a wake restarting it without reporting.

`AXTermTests/Unit/Transmission/KISSLinkNetworkReconnectTests.swift` — the
backoff table, the clamp, close meaning closed, suspend keeping the link
wanted, and the two failures not worth retrying.

`AXTermTests/Unit/Transmission/SendFailureTests.swift` — which errors are a
link being down, and the default that an unfamiliar error is a fault.

`AXTermTests/Unit/Transmission/WakeAnnouncementTests.swift` — a node that
announces arms a shot on waking, one that does not stays quiet, waking twice
does not stack two up, and switching announcing off cancels a pending one.
