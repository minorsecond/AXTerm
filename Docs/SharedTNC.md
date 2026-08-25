# Two AXTerms, One TNC

What happens when a desktop and a laptop — or a Mac and an iPad — both point
at the same Direwolf, and what AXTerm does about it.

---

## 1. What is already safe

Direwolf accepts multiple KISS clients and serialises their transmissions
through its own TX queue and channel access. **The radio layer is fine.**
Nothing here is about two stations keying at once.

The database is fine too: each device has its own, and nothing shares a file.

---

## 2. The one that actually breaks things

**Both devices using the same callsign-SSID.**

AX.25 connected mode keeps state per link — a send sequence V(S), a receive
sequence V(R), a retry timer, a window — and every bit of it assumes exactly
one station answers to an address. With two:

- both answer a SABM, so the far end receives two UAs and resets the link
- both acknowledge I-frames, so V(S)/V(R) diverge from the peer's
- a session one device opened is torn down by the other's DISC
- a Winlink P2P listener armed on each answers the same inbound call
- both retry independently, doubling the offered load on a shared channel

None of this raises an error. It looks like a flaky link, a bad path, a
gateway with problems — anything except the actual cause. That is what makes
it worth detecting rather than documenting.

### Detection

`StationIdentityMonitor`. The signature is exact: **a frame arrives whose
source is this station's own address, and this station did not send it.**

The subtlety is recognising our own frames coming back. A digipeater sets the
has-been-repeated bit on the hop it serviced, so the frame that returns is
*not* byte-identical to the one that left. Comparing bytes would fire a
collision warning on every single transmission through DRLNOD — and an
operator who sees a warning on every transmission learns to ignore the
warning, which is worse than not having one.

So transmissions are fingerprinted on the invariant part — source,
destination, control field, payload — which survives digipeating. The echo
window is 30 seconds, long enough to cover a digipeater's own channel access
on a busy channel.

Reported at most once per five minutes: a collision emits a frame every few
seconds, and a banner that reappears constantly is a banner that gets
dismissed reflexively.

The warning names the fix, because "something is wrong" costs the operator
the afternoon this exists to save:

> Give one of them a different SSID (Settings → General → Callsign). Any
> unused SSID will do; the two are then separate stations and both can share
> the TNC safely.

### Limits, stated plainly

- **Detection, not prevention.** AX.25 has no way to stop another station
  using an address, and neither does Direwolf.
- **A silent second device is invisible.** If the other AXTerm only listens
  and never transmits, there is nothing to detect — and nothing to break.
- **Identical frames are a false negative.** If the other device happens to
  send a frame identical to one we sent in the last 30 seconds, it reads as
  our echo. Accepted deliberately: the alternative is false alarms on every
  digipeated frame, and a collision produces plenty of other frames.
- **Changing callsign clears the memory,** so frames sent under the old
  identity cannot mask a real collision on the new one.

---

## 3. Winlink outbound mail

Covered by the transmit claim in `Docs/UnifiedMailbox.md` §4 — but **only when
iCloud sync is on.** The claim travels through CloudKit; two devices sharing a
TNC with sync off have no shared state and will both transmit the same MID.

With sync on, one device holds a claim for each queued message and only that
device sends it. Claims expire after 45 minutes so a device that loses power
mid-session cannot strand mail.

---

## 4. P2P listening

Arm **one device only**. An armed station answers inbound Winlink calls and
transmits in reply with no operator present. Two armed stations on the same
callsign both answer the same call; two on *different* callsigns are simply
two stations, which is fine.

---

## 5. The recommended setup

Give each device its own SSID:

| Device | Callsign |
|---|---|
| Home rig | `K0EPI-7` |
| Laptop / iPad | `K0EPI-1` |

They are then separate stations as far as AX.25 is concerned, both can share
the TNC, and:

- sessions belong to whichever device opened them
- the mailbox still syncs, because the unified mailbox is keyed on MIDs and
  the operator's account, not on the station address
- link measurements stay per-device, which is correct — `WinlinkLinkQuality`
  already refuses to treat a measurement taken elsewhere as a prediction, and
  a laptop on a different antenna is elsewhere

Note the existing constraint recorded for this station: Direwolf and LinBPQ
share the KISS port on the same host, and LinBPQ's `NODECALL` is `K0EPI-7`.
AXTerm must not use that SSID or LinBPQ answers AXTerm's sessions — the same
class of problem, with a different piece of software on the other end.

---

## 6. Tests

`AXTermTests/Unit/AX25/StationIdentityMonitorTests.swift` — 14 cases, split
between catching the collision and refusing to cry wolf:

Catching it: a frame from our address we did not send; the explanation names
the callsign, the cause and the SSID fix; an echo arriving outside the window
counts; the warning returns after the quiet period.

Not crying wolf: a different SSID is a different station; another station
entirely is ignored; our own frame coming back is ignored; **a digipeated echo
is recognised as ours**; no callsign means no detection; repeated collisions
report once.

Plus: comparison ignores case and whitespace, reset clears the echo memory,
and different frames fingerprint differently.
