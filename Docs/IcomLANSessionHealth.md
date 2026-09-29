# Icom LAN: why sessions die quietly, and what a healthy one looks like

The IC-705 over WLAN runs three UDP streams: control (50001), serial/CI-V
(50002) and audio (50003). There is no connection to lose. A radio that has
stopped serving us and a radio that is simply quiet produce the same thing at
the socket: nothing.

This document records a failure that ran for four and a half hours without
being noticed, why the existing watchdog could not see it, and the wire
measurements from a working third-party client that tell us what a healthy
session actually looks like.

> A later look at the same night found a second cause sitting under this one:
> the Mac's display slept and App Nap coalesced the app's timers, which is
> enough on its own to starve the 705 of the keepalives it expects. The 705's
> LAN session failed within a second of every display-off and recovered within
> a second of every display-on, four times for four. See
> [PowerAndLinkRecovery.md](PowerAndLinkRecovery.md). The watchdog work below
> stands — a radio that stops answering still has to be noticed — but a good
> share of the flapping recorded here was the scheduler rather than the radio.

## The failure, 2026-09-18

AXTerm was left running overnight with the 705 on WLAN.

```
19:49:55   session established (after an earlier, correctly detected drop)
00:03:15   last frame decoded
00:03:25   last carrier transition
00:03:28   CI-V: no answer, bytesInSinceOpen=143065
   ...
04:34:20   CI-V: no answer, bytesInSinceOpen=143065
```

For 4h31m the radio sent **no payload on any stream**: the CI-V inbound byte
counter never advanced past 143,065, no audio reached the demodulator, and the
data-carrier detect never changed state once. AXTerm sent 12,624 CI-V commands
into it and reported the radio as connected throughout.

The thread backtraces taken while stalled show `com.axterm.modem.dsp` parked in
`ModemEngine.runLoop()` on a semaphore, waiting for samples that never arrived,
with every dispatch worker idle. Nothing was wedged on our side. The radio had
simply stopped talking.

Earlier the same evening, at 19:49:19, the radio went *fully* silent — pings
included, and that was caught in 61 seconds and reconnected automatically 36
seconds later. **The recovery path works.** Only detection failed.

## Why the watchdog could not see it

Two decisions, each defensible alone, that cancel each other out.

`IcomLANStream.handle()` stamps liveness on every datagram, deliberately:

> Stamped first, and for *every* datagram. Pings and idles return early below
> and are the only things a radio sends when nothing is happening — a liveness
> stamp taken any further down would call a healthy but quiet radio dead.

`IcomLANLiveness` then watches control and audio, also deliberately:

> Control and audio both carry traffic continuously once connected; the serial
> stream carries CI-V only when somebody is asking the radio something, so
> quiet there is its resting state and must never be read as death.

The second reasons about **payload** — audio flows continuously once
connected. The first measures **datagram arrival**, and a ping is a datagram.
So the audio watchdog is satisfied by the audio stream's own keepalives, and
cannot detect a stream that is alive but carrying nothing. The serial stream,
the other one that died, is not watched at all.

Packet capture confirms why this is fatal rather than merely imprecise: the
radio pings all three streams on its own 10 Hz schedule, unconditionally. Its
keepalives keep ticking after its service layer has stopped, so
`audio=0.1s control=0.0s` stayed green for four and a half hours describing a
radio that had said nothing useful since midnight.

## What a healthy session looks like

Measured from a 36-minute packet capture of SDR-Control holding the same radio,
on the same network, on the same firmware (2026-09-18, 485,219 packets).

| | SDR-Control | AXTerm |
|---|---|---|
| Token renewal | 60.009 s | 60 s |
| Client ping, control | 0.100 s | 3.0 s |
| Client ping, serial | 0.101 s | 3.0 s |
| Client ping, audio | 0.100 s | 3.0 s |
| Idle on control | 0.5 s | 1.0 s when quiet |
| Idle on audio | none | none |

No gap anywhere in that capture exceeded 0.23 s.

Token renewal is identical, which rules out the most obvious suspect. The
difference is cadence: SDR-Control talks to every stream thirty times more
often than we do.

Client and radio pings run at the same 10 Hz interleaved 100 ms apart, which
means they are independent schedules rather than request and response. The
radio's keepalive is unconditional.

### The handshake, from the wire

The capture caught a full connect. Control stream, in order:

```
0x03  are you there            client -> radio, repeated until answered
0x04  I am here                radio  -> client
0x06  are you ready            both directions
0x00  login (128 bytes)        obfuscated credentials + client name
0x00  login reply (16)         radio acknowledges
0x07  ping (21 bytes)          begins, 10 Hz, both directions thereafter
0x60/0x90  capabilities (96)   radio identifies itself and the connection
0x40  token (64 bytes)         renewed every 60 s thereafter
```

Audio and serial streams are opened after the control session is established
and are pinged on the same 10 Hz schedule from the moment they open.

## Hypothesis

On the serial stream SDR-Control runs continuous heavy traffic (scope data,
about 27,000 packets each way in 36 minutes). AXTerm's serial stream is nearly
silent: one CI-V poll every few seconds and a ping every three.

The two streams that died overnight were serial and audio: the two where
AXTerm is quietest outbound. A nearly-idle stream stops being served while the
control stream, which we keep busier, survives.

This fits every observation but is not proven. The capture is of a healthy
session and cannot show a failure. The decisive experiment is to capture
AXTerm's own session and leave it until it stalls, which shows what the radio
did in the seconds before it went quiet.

## What to change

1. **Separate payload from keepalive.** Keep `lastInboundAt` stamping every
   datagram, which correctly protects a quiet radio. Add a second stamp taken
   after the ping and idle early-returns, and judge the audio stream on that.
   The watchdog's own premise, that audio flows continuously once connected, is
   true of payload and only payload.

2. **Count consecutive unanswered CI-V polls.** We poll continuously and every
   poll should be answered. Several unanswered in a row means the service layer
   is gone whatever the ping responder is doing. The failure logged 12,624 of
   these and acted on none.

3. **Match the measured cadence.** Ping all three streams at 10 Hz and idle
   control at 0.5 s. Cheap, low risk, and it aligns us with a client
   demonstrably stable against this radio. Worth doing whether or not the
   hypothesis above is right.

## Method note

The cadence and handshake here were measured by capturing UDP between the Mac
and the radio:

```
sudo tcpdump -i any -n -s 0 -w capture.pcap 'host <radio> and udp portrange 50001-50003'
```

Observation of traffic on the wire, not inspection of anybody's binary. The
wfview project is an open-source implementation of this protocol for the same
radios and is a good cross-check on the packet formats; it is GPL, so it is
useful for confirming wire facts rather than as a source of code.
