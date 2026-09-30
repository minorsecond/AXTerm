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
  (TXDELAY, P, SlotTime, TXtail, FullDuplex) are honored and update the
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

### Transmissions heard, decodable or not (`NoiseQuietingDetector`)

On 2026-09-30 an IC-705 with its notch on by accident decoded about one APRS
frame a minute on a busy 144.390. Nothing on screen was wrong: the link was
up, the level was in range, and a frame arrived now and then. With the notch
off the modem decoded 14 frames in 3 minutes, to Direwolf's 17 on the same
audio. The only sign was the gap between how much the receiver heard and how
little the modem decoded, and carrier detect cannot measure that gap because
it judges from the tones, which are what a notch or a filter removes.

With the squelch open an FM receiver plays loud hiss, and a carrier quiets
it. AFSK sits at 1200 and 2200 Hz, so 3.5 to 6 kHz is nearly all receiver
noise. `NoiseQuietingDetector` measures that band on 4096-sample frames
(85 ms at 48 kHz) and counts a transmission when a frame's energy falls at
least 6 dB under the running median of the last 128 frames (about 11 s) and
stays there for at least 0.3 s. These are the numbers the offline analysis of
the 2026-09-30 recording used. The band is cut with four high-pass sections
and one low-pass per sample: a single section passes the 2200 Hz tone only
9 dB down, and on a loud signal that tone alone fills the band. Silence (a
closed squelch) has no hiss to quiet and never counts. The detector pauses
while we transmit and through the receive mute after.

The count is `carriersHeard` in the telemetry. `ReceiveHealth` keeps a
ten-minute ledger of it against `framesDecoded` per radio
(`ReceiveHealth.CarrierLedger`, a sample every 5 s), and with at least 10
carriers and fewer than a quarter as many frames decoded it warns: "Heard 23
transmissions in 10 min but decoded 3 frames." Without CI-V the warning
suggests the notch, noise reduction, filters and audio level; with CI-V it
names what the radio's own audit found. The warning shows wherever the
quiet-receiver warning does. An idle channel never has 10 carriers, a healthy
one decodes far more than a quarter, and a hardware TNC is never judged,
having no audio to count.

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

It used to ship `[0]` — a single center slicer, assuming a flat path.
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
very same samples — comparing two decoders on two noise realizations would
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
modem's CI-V link reads the receive path's settings (attenuator, preamp, RF
gain, squelch level, noise blanker, noise reduction, auto and manual notch,
tone squelch, mode and filter) and `RigReceiveAudit` judges each against what
a soundmodem needs. Settings → Radios → the modem radio → **Check reception**.

Findings are ranked. *Blocking* is sensitivity thrown away before the modem
ever sees it — an attenuator left on, RF gain backed off, a squelch that is not
open, a narrow filter, the auto notch (it hunts for steady tones and removes
them, and AFSK is two steady tones), a tone squelch that mutes every station
not sending the tone. *Degrading* is audio the demodulator then has to fight:
NR smears the tone transitions, NB punches holes and a hole inside a frame costs
the frame, a manual notch cuts a slot that takes a tone with it wherever it sits
near one. *Suggestion* is the preamp being off, which is the right choice on a
crowded band and free margin on a quiet one.

The notch and tone squelch checks came from the 2026-09-30 failure described
under `NoiseQuietingDetector`. Their codes are in the IC-705 CI-V Reference
Guide (2020 edition, command table p. 4) and agree with hamlib
(`rigs/icom/icom_defs.h` S_FUNC_ANF 0x41 and S_FUNC_MN 0x48, both in the
IC-705's function set in `ic7300.c`) and wfview's IC-705 rig file:

| Setting | Read / write | Values |
|---|---|---|
| Auto notch | `16 41` | `00` off, `01` on |
| Manual notch | `16 48` | `00` off, `01` on |
| Tone squelch function (IC-705) | `16 5D` | `00` OFF, `01` TONE, `02` TSQL, `03` DTCS, `06` DTCS(T), `07` TONE(T)/DTCS(R), `08` DTCS(T)/TSQL(R), `09` TONE(T)/TSQL(R) |

`16 5D` is asked only of a radio at address `A4` or one whose LAN login names
it an IC-705; other Icoms split the function across `16 42`, `16 43` and
`16 4B` or put it elsewhere. A transmit-only tone (TONE, DTCS(T)) is a
repeater tone and not a receive problem, so it is never a finding, and the fix
for a receive tone squelch drops only the decoder: TSQL becomes TONE, DTCS
becomes DTCS(T), and the tone the radio sends is kept. VSC (`16 4C` on other
Icoms) is not checked: the IC-705 guide does not list it.

Two unanswered reads in a row end the audit's reads for that pass, so a radio
that has stopped answering costs two timeouts rather than nine. A radio that
lacks a setting answers NG at once and does not count.

The audit is judged against the modem mode, not against 1200-baud FM. Until
2026-09-19 it was not: the mode check was a literal `.fm`, so a 300 bd HF
station was told at blocking severity to switch to FM — on 20 m, advice that
guarantees the silence it was called to explain. The filter check sat in the
`else` of that same test, so the setting that matters most at 300 bd, where the
tones are 200 Hz apart and a narrow data filter removes one of them, was never
reached on the stations that needed it. `ModemMode.expectedRigMode` is now the
one definition of what the radio should be in, read by both `configureForPacket`
and the audit, so the two cannot drift apart again.

On an SSB mode the opposite sideband is a suggestion rather than a fault. The
tones invert with the sideband and NRZI encodes transitions rather than levels,
so LSB decodes as well as USB — provided the far end agrees. What the operator
does need telling is that `setsRadioModeOnConnect` sets the sideband at every
connect, which it says when it changes the mode.

**Check reception** is read-only; **Fix these** beside it changes only the
settings whose right value for packet is a fact, never the mode or the preamp.
The audit judges only documented Icom subcommands. A subcommand whose meaning
on this radio is uncertain is not worth a wrong answer about why nobody can be
heard.

**During the session.** The audit also runs every two minutes while the radio
is connected and idle, whether or not the frequency is followed (it used to sit
behind that switch, so a station with it off was never checked after
connecting). `RigReceiveAudit.DriftWatch` compares each pass with the last: the
first pass is the baseline, a finding that appears later is announced once in
the console ("The radio changed under us: the auto notch is on") and held
until it is fixed or put right by hand. The change is not reverted silently;
the radio is the operator's. The radio page's status section shows it with a
**Fix** button (`ModemReceiveDriftRows`), the way a TNC4's receive-level drift
is shown, and the toolbar's receive warnings list it. A fix made while AXTerm
is setting the radio up for packet joins the snapshot below and is put back at
close with everything else.

### Modes

| Mode | Tones | Baud | Radio | Notes |
|---|---|---|---|---|
| `afsk1200` | 1200 / 2200 Hz | 1200 | FM-D, DATA MOD = USB | VHF/UHF packet |
| `afsk300` | 1600 / 1800 Hz | 300 | USB-D, filter ≥ 1.8 kHz | HF; tune 1.7 kHz below the channel |
| `g3ruh9600RxIF` | — | 9600 | 12 kHz IF out | declared, receive-only, not yet implemented; hidden from the picker |

### Recording what the demodulator heard (`ModemAudioCapture`)

When nothing decodes there are two explanations that look identical from
inside the app — the signal never arrived, or it arrived and could not be
read — and no amount of staring at the radio separates them. The capture taps
the samples handed to the demodulator, after the audio device, the channel
selection and the network stream, and writes them to a plain 16-bit mono WAV.

Off unless asked for, and it records receive audio only:

    defaults write com.rosswardrup.AXTerm modemCaptureRx -bool true

Files land in the container's `tmp/axterm-modem-capture` unless
`modemCapturePath` says otherwise, and the header is rewritten on every flush,
so the file is playable while the app is still running. A recording stops after
an hour, about 330 MB at 48 kHz. Turn it off with `-bool false`.

`CapturedAudioDecodeTests` reads one back through every mode and prints the
frames, checksum failures and peak tone discrimination for each, which answers
both halves of the question at once — whether there is a signal, and whether it
is the one you thought you were sending.

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
| Attenuator (read / set) | `11` / `11 <value>` (`00` off, `20` 20 dB) |
| RF gain, squelch level | `14 02`, `14 03` + two BCD bytes, 0000-0255 |
| NB, NR, auto notch, manual notch | `16 22`, `16 40`, `16 41`, `16 48` + `00`/`01` |
| Tone squelch function (IC-705) | `16 5D <value>` |

**On connect**, with the switch off, AXTerm only identifies and reads.
**"Set radio for packet…"** is a confirmed one-shot that pushes exactly: the
mode with data on, DATA MOD (USB, or WLAN over Wi-Fi), AF squelch open, USB
SEND off, Transceive off (over a cable), the radio's four TX Delay menus off.
It never touches the frequency, and it is a permanent change the operator
asked for, so it is not put back. The confirmation sheet lists the same items
(`ModemRadioSection.setupDescription`); if the two ever disagree, the code is
wrong.

### Setting the radio up, and putting it back (`RigPrep`)

Until 2026-09-30 AXTerm wrote the operator's radio at every connect and never
undid any of it: after a session the radio sat in FM-D with its TX delays gone
and CI-V Transceive off. The TNC4 has been treated better since 2026-09-29 (the
link records what the TNC held and puts it back on disconnect), and this is the
same promise for a radio on CI-V.

With **Set up the radio for packet while connected** on
(`setsRadioModeOnConnect`), each connect runs `CIVClient.prepareForPacket`: the
one-shot's recipe, then the receive settings whose packet value is a fact,
namely attenuator off, RF gain full, squelch open, NR off, NB off, auto notch
off, manual notch off and, on an IC-705, the receive tone squelch off. The
preamp stays the operator's. Every setting is read first and written only when
wrong. A receive setting the radio will not report is left alone, because a
change whose original is unknown cannot be put back.

Every write is recorded in a `RigPrepSnapshot`: per setting, the original and
the value applied, in the order applied. The mode, filter and data flag are one
setting (`[mode, filter, data, dataFilter]`), because `06` clears the data flag
and restoring them separately could leave a radio that was in USB-D in plain
USB. The snapshot is written to `AppEnvironment.defaults` under
`rigPrep.v1.<radio ID>` (`RigPrepStore`) the moment a change is made, so it
survives a dropped link, an auto-reconnect, a sleep and a crash. A later
change to a setting already in it keeps the stored original, so a connect that
finds the radio still prepared (after a crash, say) never takes AXTerm's own
values for the operator's. A damaged entry is dropped on load and the rest kept.

**Putting it back.** `ModemRadioLink.close()` is the operator's close: a
disconnect, the radio disabled or removed, the app quitting. After PTT off on
the still-open port and before the port shuts, `CIVClient.restore` reads every
recorded setting, plans with `RigPrepRestore.plan` and writes the originals in
reverse order. A setting that no longer holds AXTerm's value was changed by the
operator during the session and is left alone; one already back is skipped; one
the radio did not report is restored anyway, since silence is no evidence of a
change. What fails, or what the 4 s budget does not reach, stays in the
snapshot for the next close. One console line says what was put back, what was
left and what could not be. A dropped link (`rigDied`), a sleep (`suspend`) and
a reopen for a settings change restore nothing; the snapshot waits for the real
close, and a reconnect started before a close finished waits for its restore.

Switching the option off while connected restores at once; switching it on
prepares at once. On quit, `applicationShouldTerminate` sees that a link owes
its radio settings (`RadioManager.hasPreparedRadios`), closes the links, and
replies once no link is still closing (`isClosingRigs`), with a backstop of the
restore budget plus 2 s. The PTT-off-first order is unchanged.

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
  (gray silent, green in range, amber above −6 dBFS, red clipping).
- **Rig control (CI-V)**: port (the serial list; the lower-numbered
  usbmodem is Port A), address in hex, keying method with its note,
  **Identify** → "IC-705 (A4) · 144.390 MHz FM-D" on the live link, or on a
  throwaway client before the radio connects.
- **Transmit**: level slider, **Test tone (2 s)** (a steady 1200 Hz mark
  through the same CSMA and PTT path a frame takes), **Send test frame** (a
  UI frame to TEST from this radio's callsign through the normal send
  path), and the max transmission watchdog. TXDELAY, TXTAIL, persistence and
  slot time are the radio page's Timing section, the same one every radio
  has, each with help that says what it is for.
- **Radio**: follow frequency, **Set up the radio for packet while
  connected** (prepare on connect, put back on disconnect or quit),
  **Set radio for packet…** with the confirmation above, **Check reception**
  and **Fix these**.
- **Status** while connected: a receive setting changed during the session,
  with **Fix**; carrier and PTT dots, decoded / failed / sent counts, audio
  format and dropouts, the radio's model · frequency · mode.

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
  capabilities, a token acknowledgment and the connection reply in an
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
3. **AXTerm.** Settings › Radios › Add Radio…, Reached by = Sound modem, USB
   cable. Audio in and out = USB Audio CODEC; after Done, on the radio's page,
   CI-V port = Port A, keying = CI-V command.
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
  frequency-offset detectors; the single center slicer already meets the
  Direwolf single-slicer baseline on the noisy fixtures.
- **Hardware verification** of every step of the checklist above on a real
  IC-705; the timing defaults (TXDELAY 300 ms, TXTAIL 100 ms) are
  conservative until measured.
