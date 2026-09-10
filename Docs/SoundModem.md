# The Sound Modem

AXTerm can be the TNC. A radio of kind **Sound Modem** (`RadioTransportKind.modem`)
takes the radio's receive audio from a sound device, decodes packet itself,
and transmits by playing audio back and keying the radio over CI-V. The first
radio it was built for is the Icom IC-705 over its USB cable, which presents
a USB Audio Class codec ("USB Audio CODEC", 48 kHz stereo) and two serial
ports, the lower-numbered of which is CI-V Port A. No driver, no external
TNC, no Direwolf.

It is one more radio in the list. Everything in [MultiRadio.md](MultiRadio.md)
applies unchanged: its own callsign, the Radio column, per-radio metrics,
per-radio services, the Auto radio. A station can run a Direwolf base
station and an IC-705 at once and see both.

## The model

```
IC-705 ──USB──┬─ USB Audio CODEC ──▶ CoreAudioModemIO ─▶ ┐
              │                                           │ AXTerm/Modem/ (pure Swift + Accelerate)
              └─ CDC-ACM Port A ───▶ POSIXSerialPort ─▶ SerialCIVTransport ─▶ CIVClient ─▶ CIVPTTController
                                                          │                                       │
                                     SoftModemLink: KISSLink ◀── PTTController ───────────────────┘
                                     (KISS in → HDLC → CSMA → AFSK → audio out;
                                      audio in → AFSK → HDLC → KISS → delegate)
                                                          │
                          ModemRadioLink: KISSLink (modem + CI-V client + PTT + status poll)
                                                          │
             RadioManager.defaultLinkFactory case .modem ─▶ LinkSession ─▶ RadioIngest ─▶ PacketEngine (unchanged)
```

- **`SoftModemLink`** speaks KISS on both faces. The engine hands it
  KISS-framed AX.25 exactly as it would a TCP TNC; decoded frames come back
  KISS-framed on the radio's port. `LinkSession`, `RadioManager` and
  `PacketEngine` do not know the modem exists. KISS command frames 1–5
  (TXDELAY, P, SlotTime, TXtail, FullDuplex) are honoured and update the
  running configuration.
- **`ModemRadioLink`** (macOS) composes the modem, a `CIVClient` on the
  configured port and the chosen `PTTController`. Opening goes CI-V first:
  identify (`19 00` must answer the configured address), CI-V Transceive
  off, an optional one-shot radio setup, one read of frequency and mode,
  then the audio devices. A wrong radio or a dead port fails before any
  sound device is taken, with one sentence saying so ("found IC-7300 (94)
  on this port, expected IC-705 (A4)").
- **Audio behind a protocol.** `ModemAudioIO` is implemented by
  `CoreAudioModemIO` (two AUHAL units, device by UID, Float32
  non-interleaved at the device's native rate, 48 kHz asked for when the
  device offers it) and by `SyntheticModemIO` for tests. The DSP never
  knows which. An Icom LAN implementation can slot in later.
- **CI-V behind a protocol.** `CIVTransport` is serial today; the LAN
  protocol carries CI-V bytes verbatim, so the client would be identical.

### Profile fields (`RadioProfile`, kind `.modem`)

`modemMode`, `audioInputDeviceUID/Name`, `audioOutputDeviceUID/Name`,
`audioInputChannel`, `civSerialPath`, `civAddress` (A4), `civControllerAddress`
(E0), `rigModel` (written by Identify), `pttMethod`, `txDelayMs` (300),
`txTailMs` (100), `persistence` (63), `slotTimeMs` (100), `txAudioLevel`
(0–100 → −40…0 dBFS; 85 is −6 dBFS), `followsRadioFrequency`,
`setsRadioModeOnConnect`, `maxTransmitSeconds` (30). All defaulted, all
`decodeIfPresent`: a profile written before the modem existed decodes
unchanged.

The **link key** is the audio pair, `modem://<inUID>|<outUID>`. Two modem
radios on one codec are one owner fight whatever their CI-V ports, and the
settings list says so (`duplicateAudioDevice`). A modem whose CI-V port is
a serial TNC's port is flagged too (`duplicateSerialPort`). The **transport
signature** adds the mode, the CI-V path, the keying method, the input
channel and the KISS port: those reopen the link; levels, timing, the
radio's frequency and its name apply in place.

## The modem

Both AFSK modes run at a 12 kHz demodulation rate after decimation from
the device rate (anti-alias windowed sinc, `vDSP_desamp`).

**Receive.** Bandpass prefilter → two quadrature tone detectors (free-running
NCOs, I/Q lowpass, power) → a level-independent ratio decision
`(m − g·s)/(m + g·s)` per slicer, where `g` is the slicer's twist hypothesis
→ a digital PLL per slicer (32-bit phase, sampled on the wrap, inertia 0.70
locked / 0.58 searching) → NRZI → HDLC (flags, bit unstuffing, abort, FCS
CRC-16/X-25 with the 0xF0B8 residue, 17…1024 bytes) → a deduplicator over
64 bit-times so several slicers hearing one frame deliver one. 300 bd uses
a sharper I/Q lowpass because its 200 Hz shift is below its baud rate.

**Transmit.** `HDLCEncoder` streams TXDELAY worth of flags, the frames with
stuffing and FCS, two flags between back-to-back frames, TXTAIL worth of
flags; `AFSKModulator` is continuous-phase with fractional samples per bit.
The engine's TX state machine is clocked in input samples, not wall time:
`idle → waitingForChannel → keying → transmitting → cooldown`. Channel
access is p-persistence CSMA (PERSIST/SLOTTIME) against a carrier detect
derived from the demodulator, not the radio's squelch (see below). **No
audio plays until the PTT controller confirms**; the transmitter unkeys
when the device has consumed every rendered sample plus the latency
margin; a watchdog forces PTT off after `maxTransmitSeconds`. Receive is
muted while keyed and for 50 ms after (the codec's TX-time audio is not
the on-air signal).

### Carrier detect

A packet radio runs with its squelch fully open, so the modem is fed band
noise at all times and `DataCarrierDetect` has to tell a transmission from
noise on its own. Two inputs it used to take turned out to be things noise
produces freely:

- **HDLC activity.** A flag is six ones between zeros, which random bits
  deliver several times a second; the decoder then latches `synchronised` and
  reports `.inFrame` until an abort.
- **PLL lock.** A phase-locked loop locks to whatever it is given, and
  `isLocked` latched besides — its transition count was a lifetime total that
  never decayed. With the nine-slicer twist comb, any one of nine independent
  PLLs locking counted.

Measured on audio containing no signal at all (`CarrierFalseDetectTests`),
the channel read busy for **90%** of the time with one slicer and **99.7%**
with the comb. The consequence was that every transmission waited out
`maxChannelWaitSeconds` and was dropped, reported to the operator as "channel
busy" on a channel nobody was using.

What noise cannot fake is the demodulator's own decision variable, which was
already being computed and thrown away: `(mark − space) / (mark + space)`
swings to ±1 when one tone is present and sits near zero when the two powers
are equal, which is what noise is. `AFSKDemodulator.toneDiscrimination`
averages its magnitude over ~24 bits — 20 ms at 1200 baud, well inside a
transmission's TXDELAY preamble. Measured over 60 s of noise and frames down
to 6 dB SNR: noise never exceeded 0.56, a signal held above 0.83, and the
threshold sits at 0.65. It also does not depend on framing or bit sync, so it
holds through the sync losses that used to release the channel in the middle
of other people's frames.

`toneDiscrimination` is published in telemetry so a channel that reads busy
can be asked why.

**Telemetry** (`ModemTelemetry`, ≤10 Hz off the audio thread): peak and
RMS level, clipping, carrier and the tone discrimination behind it, PLL lock
and jitter per slicer, frames
decoded / FCS failures / duplicates suppressed, PTT, queue depth, frames
sent, under- and overruns, audio format and latency. It reaches the radio
form's meter and status rows through `LinkSession → RadioManager →
ConnectionTransportViewModel`, and PTT and carrier transitions go to the
link debug log.

### Slicers, and why there are five

The demodulator decides mark-versus-space from a *ratio* of the two tones'
powers, so it needs no AGC — but a ratio assumes the two tones arrive at
comparable strength, and in a real receiver they never quite do. FM
de-emphasis, a radio's data-jack response and the IC-705's WLAN codec all leave
one tone louder than the other. That tilt is called twist.

Each slicer is one hypothesis about the twist, with its own bit clock, NRZI and
HDLC decoder; a frame that any of them reads is deduplicated down to one frame.
`ModemLinkConfig.slicerTwistsDB` ships nine hypotheses at 1.5 dB spacing
across ±6 dB. Both numbers are measured. Widening the span buys nothing — ±9
and ±12 score identically — while halving the step from 3 dB to 1.5 dB takes
the hardest bench condition from 15 frames of 40 to 24: a power detector in
noise gains a positive bias on *both* tones, so the best threshold sits away
from the arithmetic answer and a finer comb lands nearer it.

It used to ship `[0]` — a single centre slicer, assuming a flat path.
`AFSKSensitivityBenchTests` measures what that costs, in frames decoded of 40,
at 1200 baud and 16 kHz:

| SNR | twist | 1 slicer | 9 slicers |
| --- | --- | --- | --- |
| 8 dB | 0 dB | 40 | 40 |
| 8 dB | 3 dB | 36 | 40 |
| 8 dB | **6 dB** | **1** | **38** |
| 10 dB | 6 dB | 14 | 40 |
| 12 dB | 6 dB | 30 | 40 |
| 14 dB | 6 dB | 38 | 40 |

### The detector's integration window

Each tone detector smooths its power before the comparison, and how long it
smooths for is the other constant in the chain. It is chosen per mode
(`ModemMode.Parameters.detectorFilter`) rather than derived, because the two
AFSK modes sit at shift/baud of 0.83 and 0.67 and any threshold separating two
points that close is a coincidence dressed as a rule.

1200 baud integrates over **2.5 bit periods**; 300 baud keeps a sharp lowpass,
because its 200 Hz shift falls below its 300 bd bit rate and no short window can
separate the tones.

This used to be `if shift < mode.baud`, which is true for *both* modes
(1000 < 1200 and 200 < 300). The integrator branch beside it was unreachable,
and the comment describing 1200 baud as an integrator case described code that
had never run: 1200 baud was decoding through a filter meant for 300. Measured
at 6 dB SNR with 6 dB tilt, of 40 frames:

| detector | score |
| --- | --- |
| sharp lowpass (what shipped) | 26 |
| integrator, 1.5 bits | 31 |
| integrator, 2.0 bits | 35 |
| **integrator, 2.5 bits** | **38** |
| integrator, 3.0 bits | 39 |

The longer window is never worse anywhere in the noise/twist matrix, and costs
no inter-symbol interference: on a clean channel a 200-byte frame decodes 20 of
20 at every window from 0.75 to 3.0 bits. 2.5 rather than 3.0 because the bench
has perfect bit timing and a real channel does not.

### One transmission, one delivery

Nine slicers reading the same samples decode the same frame several times, and
`FrameDeduplicator` collapses them inside a 64-bit-time window. That window was
being measured against **each slicer's own bit clock** — a clock that only
advances when that slicer's PLL does. A slicer that misses transitions falls
behind, the clocks drift apart over a long run, and the same frame arrives
looking like two transmissions far enough apart to be genuine.

With one slicer it never showed. With nine it meant the app counting a packet, a
position or an APRS message more than once — the bench caught it scoring 45 out
of 40. The window is now measured on a sample clock the whole demodulator
shares.

### Against Direwolf, on identical audio

The bench writes each condition out as PCM so Direwolf's `atest` can decode the
very same samples — comparing two decoders on two noise realisations would
measure the noise. Run `testEmitHeadToHeadMaterial`, wrap the `.pcm` files as
16 kHz mono WAV and pass them to `atest -B 1200`:

| SNR | twist | Direwolf | AXTerm |
| --- | --- | --- | --- |
| 6 dB | 0 dB | 40 | 40 |
| 6 dB | 6 dB | 36 | **39** |
| 8 dB | 0/6 dB | 40 | 40 |
| 10 dB | 0/6 dB | 40 | 40 |
| 12 dB | 0/6 dB | 40 | 40 |

Every condition matches, and the hardest one — a weak signal *and* heavy tilt
together — now comes out ahead. That last column was 24 before the integration
window was fixed, and 1 before the slicers were.

Note what this bench does not model: perfect bit timing, no frequency error, a
single clean signal with no collisions. It is a floor on what the demodulator
can do, not a promise about a Saturday afternoon on 144.390.

A flat path costs nothing either way. With 6 dB of tilt the single slicer falls
off a cliff as the signal weakens, while the spread holds — which is exactly
the shape of a station that hears mountaintop digipeaters at 90 km and misses a
mobile at 10 km.

That station was K0EPI-7. Comparing its own reception against the APRS-IS feed
on 2026-09-09 (`LiveFeedParityTests`, `Docs/APRSMessaging.md`) showed it hearing
**14%** of frames as original transmissions where every Direwolf-based igate on
the same channel averaged **73%** — and Direwolf has run multiple slicers for
years. The radio was ruled out first: squelch fully open, FM-D, not narrow.

### Why can't I hear anybody? (`RigReceiveAudit`)

The other half of that answer is in the radio, and the radio will tell us. The
modem's CI-V link reads the receive path's settings — attenuator, preamp, RF
gain, squelch level, noise blanker, noise reduction, mode and filter — and
`RigReceiveAudit` judges each against what a soundmodem needs. Settings →
Radios → the modem radio → **Check reception**.

Findings are ranked. *Blocking* is sensitivity thrown away before the modem
ever sees it — an attenuator left on, RF gain backed off, a squelch that is not
open, a narrow FM filter clipping 1200-baud deviation. *Degrading* is audio the
demodulator then has to fight: NR smears the tone transitions, NB punches holes
and a hole inside a frame costs the frame. *Suggestion* is the preamp being
off, which is the right choice on a crowded band and free margin on a quiet one.

It is deliberately read-only — what to do about a finding is the operator's
call, on their radio — and it judges only the standard, well-documented Icom
subcommands. A subcommand whose meaning on this radio is uncertain is not worth
a wrong answer about why nobody can be heard.

### Modes

| Mode | Tones | Baud | Radio | Notes |
|---|---|---|---|---|
| `afsk1200` | 1200 / 2200 Hz | 1200 | FM-D, DATA MOD = USB | VHF/UHF packet |
| `afsk300` | 1600 / 1800 Hz | 300 | USB-D, filter ≥ 1.8 kHz | HF; tune 1.7 kHz below the channel |
| `g3ruh9600RxIF` | — | 9600 | 12 kHz IF out | declared, receive-only, not yet implemented; hidden from the picker |

### Validation against Direwolf

`TestRig/scripts/modem_xval.sh` runs Direwolf's `gen_packets` and `atest` in
the `axterm-direwolf-tools` image. Committed fixtures under
`AXTermTests/Fixtures/Modem/` (a few frames each, clean and with noise, both
baud rates) are decoded by `ModemDirewolfCrossValidationTests`; our
modulator's WAVs are decoded by `atest` (20/20). On the noisy fixtures we
decode at least what Direwolf's single-slicer baseline does.

## CI-V

`FE FE <to> <from> <cmd> [sub] [data] FD`; the IC-705 is `A4`, the
controller `E0`; `FB` is OK, `FA` is NG. One request in flight at a time
(OK/NG carry no command byte, so replies match by order); 0.5 s timeout;
echoes of our own frames (addressed to `A4`) are dropped; frames to `E0` or
the broadcast `00` that match nothing pending are unsolicited and fold into
the rig status (a transceive broadcast of the frequency when the operator
tunes).

What the app sends, byte for byte, is pinned in `CIVFrameTests`:

| Purpose | Frame |
|---|---|
| Identify | `FE FE A4 E0 19 00 FD` → `… 19 00 A4 FD` |
| PTT on / off | `1C 00 01` / `1C 00 00` |
| Read / set frequency | `03` / `05` + 5-byte BCD, LSB pair first (144.390 MHz → `00 00 39 44 01`) |
| Read / set mode | `04` / `06 <mode> [filter]` (FM `05`, USB `01`) |
| Data mode | `1A 06 <0\|1> <filter>` |
| CI-V Transceive off | `1A 05 01 31 00` |
| USB SEND off | `1A 05 01 25 00` |
| DATA MOD = USB | `1A 05 01 19 01` |
| USB AF squelch open | `1A 05 01 11 00` |
| TX Delay HF/50/144/430 off | `1A 05 00 38/39/41/42 00` |

**On connect** AXTerm only identifies, switches Transceive off and reads.
**"Set radio for packet"** (a confirmed button, or `setsRadioModeOnConnect`)
pushes exactly: the mode with data on, DATA MOD = USB, AF squelch open,
USB SEND off, Transceive off, the radio's four TX Delay menus off. It never
touches the frequency. The confirmation sheet lists the same items
(`ModemRadioSection.setupDescription`); if the two ever disagree, the code
is wrong.

**Follow the radio's frequency**: every 5 s while the modem is idle,
frequency, mode and data mode are read into `RigStatus`, republished per
radio, and written to the profile's `frequencyHz` and `rigModel` by
`PacketEngine` (a no-op when unchanged). With the switch off, one read at
connect.

### PTT fail-safes

- Keying is a CI-V command (`pttMethod .civ`) by default; RTS or DTR on the
  CI-V port are alternatives for a radio set to USB SEND = RTS/DTR; `.none`
  leaves keying to VOX.
- The serial port is opened **without touching DTR or RTS** — asserting
  them at open (as the KISS serial link does for Mobilinkd TNCs) would key
  a 705 set to USB SEND = RTS.
- PTT off is sent: when the audio drains; on key-down failure; on the
  watchdog; on engine stop; and on `ModemRadioLink.close()` **on the still
  open port before the port closes** — a close racing the unkey cannot
  leave the radio transmitting (`testClosingWhileKeyedDropsPTT`). A port
  lost while keyed is reported.
- If PTT is not confirmed within 2 s, the queued frames are dropped and
  reported; no audio has played.

## Settings

On the Mac, the Transport picker gains **Sound Modem**. The form:

- **Transport**: audio in and out (the Mac's devices, live), receive channel
  (left / right / both), mode with its radio note, the receive-level meter
  (grey silent, green in range, amber above −6 dBFS, red clipping).
- **Rig control (CI-V)**: port (the serial list; the lower-numbered
  usbmodem is Port A), address in hex, keying method with its note,
  **Identify** → "IC-705 (A4) · 144.390 MHz FM-D" on the live link, or on a
  throwaway client before the radio connects.
- **Transmit**: level slider, **Test tone (2 s)** (a steady 1200 Hz mark
  through the same CSMA and PTT path a frame takes), **Send test frame** (a
  UI frame to TEST from this radio's callsign through the normal send
  path), TXDELAY / TXTAIL / persistence / slot time / max transmission, each
  with help that says what it is for.
- **Radio**: follow frequency, set-on-connect, **Set radio for packet…**
  with the confirmation above.
- **Status** while connected: carrier and PTT dots, decoded / failed / sent
  counts, audio format and dropouts, the radio's model · frequency · mode.

On iOS the segment is hidden unless the profile already is a modem; the
form then says the sound modem needs a Mac. `RadioManager` records the
reason a radio has no link (`unavailableReasons`) so the status shows
"Choose an audio input and output device" or "The sound modem needs a Mac"
instead of a silent "disconnected".

## Wi-Fi (Icom LAN)

The radio needs no USB cable: over its WLAN it speaks Icom's network
protocol (the same one wfview and RS-BA1 use), carrying audio and CI-V
together. In the radio's form, set **Connection** to Wi-Fi and give the
radio's address, its Network user name, and its Network password (kept in
the Mac's Keychain via `RadioSecrets`, never in the radio list or its JSON).

- **Three UDP streams** — control :50001, CI-V :50002, audio :50003 — each
  with a 16-byte header, a three-way hello (are-you-there / I-am-here /
  ready), 3-second pings, and idle keepalives. `IcomLANStream` owns one
  socket and the retransmit history; `IcomLANSession` runs the login, the
  token it renews each minute, and the connection request that names the
  codec. `IcomLANPacket` is the wire format, pinned byte-for-byte against
  real IC-705 datagrams in `IcomLANPacketTests`.
- **The handshake after login is event-driven.** The radio sends its
  capabilities, a token acknowledgement and the connection reply in an
  order that cannot be assumed, so the session drives them in one handler
  and completes on the connection reply, rather than waiting for each in
  turn.
- **CI-V rides the session** (`LANCIVTransport`), so `CIVClient` is exactly
  the serial one. The IC-705 floods CI-V with spectrum-scope frames, so on
  Wi-Fi the login itself identifies the radio and `identify` is best-effort
  — it never blocks the audio path.
- **Audio is the point, and the radio picks the rate.** An IC-705 streams
  **16 kHz** over Wi-Fi whatever rate we request (664-byte datagrams,
  640 bytes of 16-bit mono PCM each). `LANModemAudioIO` measures the actual
  rate over the first 0.7 s and builds the modem's DSP to match; a wrong
  rate decodes nothing. 16 kHz is ample for 1200 and 300 baud AFSK. A small
  reorder buffer (`SequenceReorderBuffer`, 100 ms) puts datagrams back in
  order, asks for brief gaps to be re-sent, and pads the rest with silence
  so the stream keeps time.
- **One client.** The radio allows a single network controller. `close()`
  releases the token and sends the disconnect before the sockets close, and
  the hello retries for a few seconds so a reconnect after a dropped client
  recovers once the radio lets go.
- **A refused login means "wait", not "wrong password".** After an unclean
  exit — an Xcode stop, a crash, a lost network, none of which run any
  cleanup we could write — the radio holds its one slot for tens of seconds
  and refuses a fresh login the whole time, with a refusal byte-for-byte
  identical to a bad password. So `performOpen` resends the login five
  times over 12.5 s and only then reports bad credentials.

  The radio refuses in **either of two shapes**: a login reply saying
  `accepted=false`, or an asynchronous auth-failed *status* packet. Both
  must feed the ladder. They did not: the ladder waited only for a reply,
  so a status refusal fell through to `handleControl`, which failed the
  connect on the first attempt and skipped all five retries — which is why
  a relaunch after an unclean exit needed the operator to power-cycle the
  radio. `IcomLAN.isLoginAnswer` / `isLoginRefusal` are the rule, pinned in
  `IcomLANPacketTests`; routine periodic status must *not* count as an
  answer, or the ladder burns its attempts on a radio that never said no.

### Noticing that the radio has gone

UDP has no connection to lose. A radio that drops us, a router that stops
forwarding, and macOS refusing the app local-network access all look identical
from inside: our datagrams keep being accepted and nothing comes back. Silence
is the only evidence there is, so it is measured.

`IcomLANStream` stamps `lastInboundAt` on **every** datagram — the stamp is the
first line of `handle`, before the early returns for pings and idles, because
those are the only things a radio sends when nothing else is happening. A
watchdog stamped from `onPacket` would call a healthy but quiet radio dead.

`IcomLANSession` checks once a second and fails the session after
`IcomLANLiveness.silenceLimit` (10 s) of quiet on the **control or audio**
stream. Both carry traffic continuously — the radio pings control several times
a second, and audio is a packet every few milliseconds. The CI-V stream is
deliberately not watched: it carries traffic only when somebody is asking the
radio something, and quiet there is its resting state.

**The stamp is per session, not per stream object.** `IcomLANStream` objects
are reused across connect/disconnect cycles, and `connect()` resets every
per-session counter for that reason — `lastInboundAt` was missing from the
list. It survived into the next session, so the watchdog's first tick on a
freshly connected radio measured silence from the *previous* session's last
packet and failed it one second after it connected. On 2026-09-09 the IC-705
dropped the session itself at 13:04:30; every reconnect after that died at
+1 s, leaving CI-V answering nothing (the whole bring-up ran against a session
that had just been failed) and the modem reporting "the radio's network session
is not up". Control is stamped continuously through the login, so it was the
audio stream's stale stamp that decided it: the watch takes the *quieter* of
the two. A stream that has heard nothing has `lastInboundAt == 0`, `silence`
returns nil and no verdict is reached, which is what a just-connected session
must look like.

The failure then has to travel. `IcomLANSession` → `LANCIVTransport` →
`CIVClient.onTransportFailure` → `ModemRadioLink.rigDied`, which stops the
modem, reports the reason to the operator, sets the link failed and schedules
the same backoff a failed open uses. That last hop is a separate hook because
`onTransportState` belongs to the PTT controller and there is only one of it.

This is written from a real failure. On 2026-09-09 at 11:48:49Z macOS refused
the app local-network access on `en7`, the three sockets to the IC-705 died,
the radio stopped showing a client — and AXTerm reported it as connected for
the next two hours without receiving a frame. The session's only liveness check
was the once-a-minute token renewal, which watched the control stream's answers
alone and took two minutes to conclude; and nothing carried a post-open failure
out to the link at all, so even a detected loss changed nothing the operator
could see.

Proven against a real IC-705 on 144.390: login, 16 kHz audio, and live APRS
frames decoded through the full modem over Wi-Fi with no checksum failures.
The link key is `modem://lan/<host>:<port>`, so a Wi-Fi radio is one more
row beside a Direwolf and a USB radio.

## Hardware checklist (IC-705 over USB)

1. **Radio menus.** SET › Connectors › CI-V: address `A4h`, CI-V Transceive
   OFF (AXTerm sets it too), USB Echo Back OFF. MOD Input › DATA MOD = USB.
   USB SEND/Keying › USB SEND = OFF (or USB (A) RTS / DTR for those keying
   methods). USB AF/IF Output › Output Select = AF, AF Output Level ≈ 50 %,
   AF SQL = OFF (OPEN). TX Delay (HF / 50M / 144M / 430M) = OFF. USB (B)
   Function = OFF.
2. **Mac.** `ls /dev/cu.usbmodem*` shows two ports; the lower suffix is Port
   A. System Settings › Sound lists "USB Audio CODEC" in and out at 48 kHz.
3. **AXTerm.** Settings › Radios › Add Radio › Sound Modem. Audio in and
   out = USB Audio CODEC, CI-V port = Port A, keying = CI-V command.
   **Identify** answers "IC-705 (A4) · <frequency> <mode>". Allow the
   microphone prompt: AXTerm listens to the radio through the codec; nothing
   is recorded and no audio leaves the Mac.
4. **First receive.** 144.390 FM-D, squelch open. The meter sits in the
   green on packets; the first decode appears in Packets with the Radio
   column reading IC-705.
5. **First transmit.** Test tone: the radio's TX indicator lights, ALC barely
   moves — adjust the transmit level (and USB MOD Level) until it does.
   Send test frame: Direwolf on the base station decodes a UI frame to TEST.
   PTT drops within TXTAIL. Prove the watchdog with max transmission = 3 s
   and a longer tone.
6. **Both radios.** Direwolf base and IC-705 connected at once. A station
   heard on both frequencies shows both radios; a connect's Auto radio
   explains its choice.

## What a station without a modem radio must never notice

Nothing here is reachable until a radio of kind `.modem` exists. The
Transport picker has one more segment on the Mac and nothing else moves:
`RadioStatusSummary`'s new fields are nil for a TNC radio, so every pinned
string in `RadioPresentationTests` is unchanged; the modem-only delegate
methods have empty default implementations.

## Sources and originality

Algorithms were studied in Direwolf (demodulator design, `gen_packets` /
`atest` as the independent check) and the Mobilinkd TNC4 firmware (PLL
inertia, slicer twists), both GPL. **Every line here is original Swift**;
nothing was copied. Accelerate is the only DSP dependency.

## Not done yet

- **iOS over Wi-Fi.** The LAN path is pure `Network.framework` and DSP, so
  it could run on iPhone/iPad; only the settings form and the factory are
  macOS-gated today. Enabling it is a UI job, not a protocol one.
- **9600 bd G3RUH** over the 12 kHz IF (receive only on this radio).
- **Several slicers** at once (twist hypotheses ±3/±6 dB) and 300 bd
  frequency-offset detectors; the single centre slicer already meets the
  Direwolf single-slicer baseline on the noisy fixtures.
- **Hardware verification** of every step of the checklist above on a real
  IC-705; the timing defaults (TXDELAY 300 ms, TXTAIL 100 ms) are
  conservative until measured.
