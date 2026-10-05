# Mobilinkd TNC4

How AXTerm works with a Mobilinkd TNC4, and what we learned about the TNC4
getting there. Measurements are from a TNC4 Rev B on firmware 2.5.14, taken
on 2026-09-29 with an Icom IC-V8 on 144.390 and 145.050 MHz.

Code: `Transmission/MobilinkdTNC.swift` (commands),
`MobilinkdDeviceState.swift` (replies), `MobilinkdSettings.swift` (per-radio
settings), `MobilinkdSession.swift` and `MobilinkdSessionDriver.swift` (what
happens on connect and disconnect, and timed level recordings),
`TNC4LevelSampling.swift`, `MobilinkdLevelAssistant.swift`,
`KISSLinkBLE.swift` and `KISSLinkSerial.swift` (transports),
`Radio/ReceiveLevel/` (receive-level calibration and the drift watch),
`Radio/ReceiveHealth.swift` (the deaf-receiver warning), and
`Settings/MobilinkdSettingsSections.swift` and `ReceiveLevelTuningRows.swift`
(the settings page).

The command set comes from the firmware source, checked out as the
`tnc4-firmware` submodule (`Core/TNC/KissHardware.hpp` and `.cpp`). Mobilinkd's
own configuration apps for iOS, Android and Python (all Apache-2.0) were read
for protocol details and setup wording; no code was copied from them.

## Connecting

Over Bluetooth LE AXTerm recognizes a TNC4 by its service UUID
(`00000001-ba2a-46c9-ae49-01b0961f68bb`). A serial port can't say what's on it,
so a TNC4 on USB is marked as one in the radio's settings.

When the link comes up AXTerm:

1. Sends the radio's KISS timing: TX delay, persistence, slot time and tail.
2. Asks for the firmware version, and reports the link connected only once the
   TNC4 answers. About one Bluetooth connection in four came up with
   notifications "enabled" and never delivered a byte, while writes still
   reached the TNC4. Over Bluetooth AXTerm drops such a connection and makes a
   new one, up to three times. Over serial it carries on as a plain KISS TNC and
   says so.
3. Reads the settings it manages (output gain and twist, input gain and twist,
   modem type, PTT style) with individual queries.
4. Applies the radio's own settings where they differ, then sends RESET.

On disconnect it puts back every setting it changed and waits 1.2 s before
dropping the link. Quitting AXTerm allows for this too.

## Per-radio settings

A TNC4 often moves between radios, and settings that suit one radio's audio are
wrong for another's. Each radio profile keeps its own TNC4 settings, and each
field is either set for that radio or left as the TNC4 has it. AXTerm applies
the set fields when the radio connects and restores the TNC4's own values when
it disconnects. None of this is written to the TNC4's flash, so another radio,
or another app, finds the TNC4 as its owner left it.

The radio's page (Settings › Radios), under Connection, shows:

- The TNC4's model, firmware, serial number and battery.
- Receive audio: a live level meter, receive-level calibration and the
  half-hourly level check (see "Receive-level calibration" below), input gain
  and twist, and "Find the right gain".
- Transmit audio: output level and twist, and test tones.
- Radio interface: PTT style and modem type. TX delay, persistence, slot time
  and TX tail are the page's Timing section, sent on every connect and again
  when changed while connected.
- Save, which writes what the TNC4 is using now into its flash. It asks first,
  because the TNC4 then starts with those settings with every radio. A radio
  with its own settings in AXTerm still gets them on connect.

### Finding the input gain

With the radio's squelch open on a quiet channel, the assistant measures the
noise at each input gain from the lowest up and keeps the first gain that fills
at least 30% of the range without clipping. It prefers the lowest workable gain
because the input recovers from an unkey sooner at low gain (see "The unkey
jolt" below). If the lowest gain clips, turn the radio down; if the highest is
too quiet, turn it up.

Noise is a poor stand-in for packets. On 2026-09-30 open-squelch noise filled
55% of the range while a real packet's tones arrived at 16%, so a gain chosen
from noise can leave packets 10 dB quieter than intended. Receive-level
calibration measures the packets themselves and is the better tool where it
can run.

The firmware's own auto-adjust (`06 2B`) isn't used, and AXTerm has no way
to send it. It saves its result to flash, changing the TNC4 for every radio.
In firmware 2.5.x it also judges 14-bit readings against a 12-bit full scale:
`AudioLevel.hpp` has `vref = 4095` ("Must match ADC output (adjust when
oversampling)"), while the ADC is oversampled 16 times and shifted right 2,
so its samples run to 16,383. `adjust_input_gain` in `AudioLevel.cpp` then:

- picks `gain` from `vref / vpp`, about two steps (12 dB) lower than the same
  formula with 16,383, except where it is already at 0 or +24 dB;
- tests for clipping at the top with `vmax == vref`, which a clipped input
  (16,383) never matches;
- loops with no timeout while `vmin == 0` at gain 0, so an input clipping at
  the bottom holds the audio task, and the TNC4 neither decodes nor streams,
  until the audio itself stops clipping.

### Test tones

A test tone keys the radio and holds it keyed until it is stopped. AXTerm asks
before sending one and stops it after 10 seconds regardless. The output level
can be changed while it plays. Mobilinkd advises keeping output gain at 64 or
below for a handheld, whose mic input expects very low levels.

## Receive level

The right input gain puts packet tones in the middle of the TNC4's range, and
stays right only as long as nobody touches the radio's volume.
AXTerm sets it per radio from packets it measures, watches for it drifting,
and does both with the one radio and what's on the air. No second receiver
is involved.

Every measurement streams input levels (`06 05`), which turns the TNC4's
demodulator off, and ends with RESET, including when it is canceled, fails,
or the link closes. A link that drops can't send one; the next connection
restarts the demodulator and its connect sequence ends with RESET anyway.
Changes go into the radio's managed input gain like any other setting:
applied in working memory while connected, the TNC4's own put back on
disconnect, never saved to flash, and never through the firmware's
auto-adjust.

### Level reports

Each report is `06 04` and four big-endian 16-bit values: Vpp, Vavg, Vmin,
Vmax. They are raw ADC samples, not centered on zero, so a quiet input sits
near mid-scale. The ADC is 12 bits, oversampled 16 times and shifted right 2
(`main.c`, `MX_ADC2_Init`), giving 14-bit samples, and every value is shifted
left by the demodulator's ADC exponent, 2 for AFSK 1200, 9600 and M17
(`AudioInput.cpp`). Full scale is therefore 65,532, in steps of 4
(`MobilinkdInputLevel.fullScale`). A report touched an end of the range when
Vmin is 0 or Vmax is 65,400 or more, about 33 ADC counts under the top; the
firmware's own gain code treats Vmin 0 as clipping the same way.

When no ADC block arrives within its 1 s wait, the stream sends a report
built from no samples: Vmin and Vmax keep their starting values (shifted to
65,532 and 0), Vpp wraps to 4, and Vavg divides by zero. Read as a level it
is near-silence. `MobilinkdTNC.parseInputLevel` drops any report whose Vmin
is above its Vmax, so nothing downstream sees one, and a recording counts it
as a gap in the stream.

A poll (`06 04` sent) is answered twice: `04 00` at once, then the levels.
The short reply is ignored.

### What a packet looks like in the level stream

The TNC4 sends a level report about ten times a second in 1200 baud mode
(30 blocks of 88 samples at 26.4 kHz per report, `AudioInput.cpp`,
`streamLevels`). On 2026-09-30, with the IC-V8's squelch open on 144.390,
each packet left the same trace:

1. Open-squelch noise at 30,000 to 40,000 peak to peak (about 55%).
2. The sending station's carrier, quieting the noise to about 560.
3. The AFSK tones, steady at about 10,500 (16%) for the half second to a
   second the packet lasts.
4. Noise again.

With the squelch closed, the noise is replaced by silence and the trace is
silence, tones, silence. `PacketToneSignature` looks for a steady run of
reports that starts right after a much quieter one:

| Rule | Value | Why |
|---|---|---|
| Quiet report before the tones | at most 15% of the tone level (-16.5 dB), within 2 reports | The carrier was 25 dB under the tones and a closed squelch about 30 dB. The tones at the end of a packet were only 10 dB under the noise that followed, and must not pass for a carrier. |
| Steadiness | every report within ±30% of the run's median | AFSK has a constant envelope; one packet's reports varied by a few percent. |
| Length | 3 reports (0.3 s) to 4 s | The shortest useful APRS frame takes about 0.3 s; 256 bytes with a 500 ms preamble takes 2.3 s. |
| Apart from the floor | at least 15% from the clean reports between packets | Rejects the noise that comes back after a carrier with no data on it. |

All the rules are ratios, so they hold at any gain step. Clipped reports can
be part of a run (the packet is then marked clipped) but never count as the
quiet report, because an input pinned at one end, as after the IC-V8 unkeys,
reads as a small peak-to-peak.

The first report of the tones is the transmission's onset, and a packet
longer than 3 reports takes its level, and whether it clipped, from the
reports after it. On 2026-10-04 every packet from an IC-705 reached an
ID-50's TNC4 with its first report swinging about twice as wide as the tones
that followed (+6 dB), off center by up to 14,000. At +18 dB that report read
54% beside 27% tones and stayed out of the run. At +24 dB it touched the top
rail; clipping cut its peak-to-peak to within 30% of the 54% tones, so it
joined the run and marked the whole packet clipped, and calibration stepped
down a gain it then stepped back up to ten minutes later. Tones that really
are too loud clip in every report and are still marked. The onset comes about
300 ms after the carrier, in the preamble flags, so it costs no decoding.
Whether it starts in the 705's transmit audio or the ID-50's receiver isn't
known yet; AXTerm's modulator fades in over 2 ms and holds its level. A
clipped onset is named in the calibration's evidence.

### Choosing the gain

Input gain steps are 0 to 4: follower mode, then PGA gains of 2, 4, 8 and
16 (`AudioLevel.cpp`, `set_input_gain`), shown as 0 to +24 dB. One step
doubles the peak-to-peak of everything at the input until it reaches full
scale, so one measurement predicts every other step (`ReceiveGainAdvice`).

- Aim for packet tones near 45% of full scale. The firmware's auto-adjust
  is meant to fill the range with whatever is on the input, usually noise
  (in 2.5.x it lands about two steps under that; see "Finding the input
  gain"); tones need more headroom because stations' deviation differs by
  3 dB or so.
- Never pick a step predicted above 80%.
- Take the lowest step within 1.5 dB of the one nearest 45%. Less gain
  recovers sooner after an unkey. Today's 16% sits almost exactly between
  +6 dB (32%) and +12 dB (64%); +6 dB wins.
- Anything from 30% to 70% is fine. If even +24 dB leaves packets under 30%,
  AXTerm sets +24 dB and says to turn the radio's volume up. If even 0 dB puts
  them over 80%, or they clip at 0 dB, it says to turn the volume down.
- Clipped tones only give a lower bound, so the advice is one step down and
  calibrate again.

### Calibrating an APRS radio

"Calibrate receive level…" in the radio's Receive audio section asks first,
then:

1. Waits for the radio to be idle, and for the ten-minute limit (below).
2. Arms a recording, then sends the radio's own beacon once through the usual
   beacon path, with its own path and SSID.
3. When the link writes the frame, estimates when the TNC4 will finish sending
   it: 0.1 s for the link, the TX delay, the frame at 1200 bps with 5% for bit
   stuffing, and the tail (`TNC4Airtime`). The stream must not be running when
   the TNC4 keys up or unkeys: both post to its audio task and end the stream
   (`HDLCEncoder.hpp`). If it stops anyway, AXTerm asks again, twice at most.
4. Streams from 0.3 s to 6 s after that estimate, which covers fill-in and
   wide digipeaters, then sends RESET.
5. Finds the packets, takes their median tone level, and sets the input gain
   the rules above choose. Reports within 3 s of the unkey are left out of the
   noise floor, because the IC-V8's jolt pins the input for up to 2.7 s.

Calibrating applies the result straight away, because the operator asked for
it; the result says what changed and offers Undo. For example: "Set to +6 dB.
Heard 2 digipeats at 16% at 0 dB. +6 dB puts them near 32%." The tooltip lists
each packet (when, how loud, how long, the carrier before it), the noise
between packets and the aim. Packets heard in the window are taken as the
beacon's digipeats; any packet serves to measure level.

If no packet is heard, nothing changes: "No digipeater was heard in the 6 s
after the beacon, so nothing was changed. Try again after 10:15, or check the
radio's volume, squelch and antenna."

The TNC4 doesn't decode during the window, so those digipeats don't appear in
the log, and the calibration beacon is left out of the digipeat check.

APRS etiquette: one beacon per calibration, and no calibration beacon within
ten minutes of the last on that radio (`CalibrationBeaconLimit`). The time is
stored with the radio's record, so restarting AXTerm doesn't reset it. Ten
minutes is the usual fixed-station beacon interval. AXTerm never sweeps gains
by sending more beacons.

### Packet channels

No calibration beacon, ever. The drift watch's samples (below) sometimes
catch a packet; each one's tone level is kept, carried to the current gain
at ×2 per step. With three or more from the last day, the page recommends a
gain from their median and offers "Use +12 dB" (or whichever). Until then it
says how many it has and points to the level meter.

### The drift watch

While a TNC4 radio is connected, AXTerm takes a 2 s level sample about every
30 minutes (±5 minutes, so radios don't all go deaf together; the first two to
three minutes after connecting), and sends RESET after it. It skips a sample,
and tries again shortly, while the TNC4 is measuring or sending a tone from
the settings page, while a calibration is running, or within 5 s of a frame
received or sent. A frame going out mid-sample ends it: RESET goes first, so
the demodulator is back for CSMA. That leaves the TNC4 unable to decode for
about 0.1% of the time. A switch on the Receive audio section turns it off.

Each sample records the noise floor (the median of the clean reports between
packets), the share of reports that clipped, and any packets' tone levels.
The first sample at a calibration's gain fills in its noise floor if the
calibration couldn't measure one.

`ReceiveLevelDrift` compares samples with the calibration, gain steps taken
out (6.02 dB each):

| Rule | Threshold | Why |
|---|---|---|
| Noise floor moved | 4 dB, two samples in a row, same way, at most 2 h apart | 2 s noise floors wandered about ±1.2 dB with nothing touched; 4 dB moves packets from the middle of the 30-70% band past its edge. Two in a row rules out one burst of interference or another station's carrier. |
| Packet tones moved | 6 dB, two samples with packets in a row | Stations' deviation differs by about 3 dB, and a sample catches whoever is on. |
| Packets clipping | two samples with packets in a row, both clipped | Clipped packets are lost now. |

With no calibration there is nothing to compare against, but one reading is
wrong on its own: an input pinned at an end of the range. Two samples in a
row, at most 2 h apart, with more than 20% of their reports at an end raise a
finding that says so and points at the radio's volume and the tuning wizard
(`ReceiveLevelDrift.assessUncalibrated`). Until 2026-10-01 an uncalibrated
radio could raise no finding at all, and Station B's TNC4, at its own +24 dB,
read fully clipped in every sample of the day without a word.

Readings that fill the range only bound the change: noise pinned at full
scale can show the audio got louder but not by how much, and a calibration
whose noise already filled the range can only show it got quieter. A
calibration noise floor under 5% of full scale means the squelch was closed;
the noise test is then off for that radio and only packets count.

This has limits worth knowing. With the squelch open and the gain set for
packets, noise often fills the range, and then only packets can show the
audio got louder. With the squelch closed, only packets count at all. Both
depend on a sample happening to catch a packet.

### The digipeat check

On an APRS radio, AXTerm remembers which digipeaters repeat the UI frames
this radio sends through a path (beacons, messages, objects), crediting a
repeat heard up to 30 s after sending to the station in the last used hop
(`DigipeatExpectation`, last 20 frames). If three frames in a row come back
from nobody, and at least five earlier frames were repeated by a digipeater
that repeated 60% or more of them, that's a finding. It can't tell a receive
problem from a transmit problem, and says so in the tooltip.

### Receive health

`ReceiveHealth` flags a connected radio of any kind that looks deaf, from its
own traffic:

- Nothing decoded for 20 minutes on an APRS channel, or 60 on a packet
  channel, counted from the later of the last decoded frame and the moment
  the link came up.
- Or at least 3 frames sent since the link came up, at least 5 minutes ago,
  and nothing decoded since.

A radio that has just connected is never flagged. On 2026-09-30 a TNC4 heard
nothing for 40 minutes because of the radio's antenna and nothing on screen
said so; this is the rule that says so now.

A sound-modem radio has a third rule, hearing traffic and decoding little of
it, which needs the audio and so never applies to a TNC4 (see
`NoiseQuietingDetector` in `Docs/SoundModem.md`).

### What the operator sees

Findings show on the radio page's status section, in the TNC pill's tooltip
and menu on the Mac, and in the TNC strip on iOS, next to the receive-health
line. Each has a tooltip with the evidence: the calibration it's compared
against, the samples, the change in dB, and the rule. For example: "Receive
audio on TNC4 Mobilinkd is about 8 dB louder than when calibrated at 10:05.
The volume may have been moved."

AXTerm never changes the gain on its own after a finding. Retune does:

- On an APRS radio, Retune runs a calibration (one beacon, the ten-minute
  limit applies).
- On a packet radio, it offers the step that would undo the change ("Use
  +0 dB"), or the tuning wizard when there's nothing to go on.
- When the step needed is outside 0 to +24 dB, the finding says which way to
  turn the radio's volume instead.

### The tuning wizard

"Tune the TNC4" puts the receive pieces in order for one radio
(`TNC4TuningFlow`, `TNC4TuningSheet`):

1. Start: what it does, and that nothing is saved to the TNC4.
2. Receive gain: squelch open on a quiet channel, then the gain finder above,
   with the level meter running. Next waits for a usable gain; clipping even
   at 0 dB has to be fixed with the radio's volume first.
3. Squelch: back to normal.
4. Packets: on APRS, one calibration beacon (the ten-minute limit applies); on
   packet, a 30 s listen for other stations, which feeds the packet-based
   advice and offers its step once three packets are in. Either can be
   skipped. With the squelch open, packet tones usually arrive under the
   receiver's noise, so the packets' gain can pin the noise the receive gain
   step measured as clean; when the latest check's noise floor would reach
   90% of full scale at that gain, the step says so and suggests closing the
   squelch (`TNC4TuningFlow.pinsNoise`). On 2026-10-01 an ID-50 with its
   squelch open measured noise at 44% and packets at 13% at +12 dB; with the
   squelch on auto, +24 dB put packets at 53% with silence between them.
5. Done: the radio's gain now against what it was.

Every change goes into the radio's managed input gain through the radio
page's own view model. Cancel puts that setting back as it was when the
wizard opened, including "the TNC4's own", whatever the finder tried on the
way.

It opens from "Tune This TNC4…" in the Receive audio section, from a
finding's button when the meter was the only advice, and from a one-line
suggestion on the radio page for a connected TNC4 radio with no calibration
and no gain of its own. "Not Now" hides the suggestion for that radio.

### What is kept

Per radio, in the settings store's defaults under `receiveLevel.v1.<radio>`
(`ReceiveLevelRecord`): the calibration baseline (time, gain, packet tone
level, noise floor, and how many packets it came from), the last 12 samples,
the last 24 packet levels, the time of the last calibration beacon, the last
20 frames for the digipeat check, the watch switch, and whether the operator
said not now to tuning. Every field decodes
tolerantly, so a record from another build loads with defaults for what it
lacks.

Calibration start and end, each recording window, each sample and each
finding as it appears or clears go to breadcrumbs (`tnc4.receiveLevel`), the
transmission log and the event log. New findings also get one console line.

## Things the TNC4 does that matter

### Commands that stop the receiver

The TNC4 decodes packets in its audio task, and any message to that task ends
the demodulator. Only three things start it again: RESET (`06 0B`), the end of
one of its own transmissions, or a new connection (`AudioInput.cpp`,
`startAudioInputTask`). These all go through the audio task:

- battery poll (`06 06`)
- GET_ALL_VALUES (`06 7F`)
- input level poll or stream (`06 04`, `06 05`)
- input gain and twist changes (`06 02`, `06 18`)
- modem type change

AXTerm used to poll the battery five seconds after connecting and every minute
after that, which left the TNC4 deaf until the next transmission. Every command
in that list now goes out with a RESET after it, and the battery is polled every
five minutes. In the same two-minute listening test, packets decoded went from 5
to 16. A ten-minute run afterwards decoded 84 packets, 5 to 13 in every minute,
through two battery polls.

Mobilinkd's configuration apps never send RESET, so a TNC4 that has just been
configured in one of them stops decoding until it transmits or reconnects.

### GET_ALL_VALUES can hang firmware 2.5.14

GET_ALL_VALUES queues a battery measurement and a twist measurement on the audio
task. The twist measurement waits for samples with no timeout. Sent soon after
a connect, the TNC4 answered the first line of the reply and stopped. About
8 seconds later it rebooted, when the audio queue (depth 8) filled and the next
post blocked the task that handles commands. AXTerm doesn't send it. The
settings page reads the same information with individual queries.

Several connect/disconnect cycles within a minute have also left the TNC4 hung
until it rebooted, and a new connection made a few seconds after closing the
last one sometimes didn't come up. Both only happened under test.
Auto-reconnect recovers from them: after a power cycle mid-session the link
reconnected by itself and went straight back to decoding.

### Settings live in RAM until saved

Every SET command changes the TNC4's working copy only. Flash is written by
SAVE (`06 2A`), and by the firmware's own auto-adjust. A power cycle brings
back what was saved.

### Modem types

Firmware 2.5.14 accepts 1200 baud AFSK (1), 9600 (3) and M17 (5). It defines
300 baud (2) and then refuses it. The digipeater and beacon commands in
Mobilinkd's Python app belong to a later firmware; 2.5.14 doesn't implement
them.

## The IC-V8

### The unkey jolt

When the IC-V8 unkeys, its audio output shifts enough to pin the TNC4's input at
full scale. Polling the input level every 0.4 s after a transmission gave:

| Input gain | Pinned at full scale | Back inside the range | Centered again |
|---|---|---|---|
| 4 (+24 dB) | +1.4 to +2.7 s | about +3.0 s | about +5 s |
| 1 (+6 dB) | +1.5 to +1.8 s | about +2.3 s | about +3.4 s |
| 0 (0 dB) | briefly at +1.4 s | about +1.9 s | about +2.8 s |

It was the same at output gain 63 and 128, at high and low RF power, and after
a TNC4 power cycle, so it isn't RF pickup. The radio's audio is fine by ear.

A node's reply that lands in that window is lost. A BPQ node answering a SABM
sends its UA about a second after the carrier drops. At gain 4 the TNC4 missed
every UA and welcome. At gain 0, with the radio's volume at 3, the handshake
completed in the last two runs. The node's `TXDELAY` (150 ms on K0EPI-7) could
be raised to 400 or 500 ms to cover the rest.

Low gain isn't free, though. At the same volume (3), alternating 90-second
windows on 144.390 gave 15 packets at gain 0 against 30 at gain 4: the weaker
stations fell below what the TNC4 could decode. So get the level from the
radio's volume and keep the TNC4's gain as low as that allows. Turn the IC-V8
up, then run "Find the right gain", which keeps the lowest gain that still
fills the range. At volume 3 it chose gain 3, so volume 3 is too low for
gain 0.

### Compared with an ID-50

The same TNC4 on an Icom ID-50 (volume 10, input gain 0), with the same
test: while transmitting, the input sat quiet near center, and by +1.5 s it
was back to normal noise, centered, with nothing pinned and no drift. Two node
handshakes in a row caught every reply, including the UA that comes straight
after AXTerm's own transmission: SABM and UA, the welcome, the RR, then DISC
and UA. So the jolt comes from the IC-V8 or its cable, not from the TNC4.

On the ID-50, volume 10 clips at the TNC4's gain 4 and gives a clean level
at gain 0.

### TX delay

The IC-V8 takes about 300 ms to get on the air after PTT. At the TNC4's default
TX delay of 300 ms almost no preamble made it out: the 705 decoded the packets,
but no digipeater repeated them. At 500 ms about 0.35 s of preamble reached the
air. Set the radio's TX delay to 500 ms in AXTerm.

## Testing

`AXTermTests/Integration/TNC4BLEReceiveLiveTests.swift` runs against a real
TNC4 over Bluetooth LE and is skipped unless `TEST_RUNNER_AXTERM_TNC4_BLE=1` is
set. The receive-only tests read settings, measure levels, run the level
assistant and check that applying and restoring settings works. The tests that
transmit (an APRS status, a connect to a node, a post-transmit level
measurement) also need `TEST_RUNNER_AXTERM_TNC4_TX=1`. Check the frequency
first.

Unit tests cover the command bytes, reply parsing, the settings diff and
restore, the level assistant and the profile migration. For receive level
(`AXTermTests/Unit/Radio/ReceiveLevel/`, `MobilinkdLevelSamplingTests`): the
packet finder against synthetic recordings built from the 2026-09-30 numbers,
the gain choice, the drift and digipeat rules, the calibration beacon limit,
the stored record, the monitor against a stand-in TNC4, and the driver's
recordings against a link that only records what it's sent, checking that
every stream ends with RESET when it completes, is canceled, meets a frame
going out, a tone, a settings change, or a closing or dropped link.

Not yet tested on hardware: calibration and the drift watch. The window
timing and the packet finder are built from one afternoon's level traces on
an IC-V8; other radios' carriers and squelch tails may need the thresholds
adjusted.

`TNC4SerialLiveTests.swift` does the same over USB and is skipped unless
`TEST_RUNNER_AXTERM_TNC4_USB=1` is set. On 2026-09-29 it confirmed the session,
applying and restoring settings, measuring, and a five-minute receive
(38 packets). When the cable was pulled mid-session, the link noticed at once,
retried with backoff, and was back and decoding about 16 seconds later.

Not yet tested on hardware: Bluetooth on iOS, where the link also stops when
the app goes to the background.
