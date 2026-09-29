# Mobilinkd TNC4

How AXTerm works with a Mobilinkd TNC4, and what we learned about the TNC4
getting there. Measurements are from a TNC4 Rev B on firmware 2.5.14, taken
on 2026-09-29 with an Icom IC-V8 on 144.390 and 145.050 MHz.

Code: `Transmission/MobilinkdTNC.swift` (commands),
`MobilinkdDeviceState.swift` (replies), `MobilinkdSettings.swift` (per-radio
settings), `MobilinkdSession.swift` and `MobilinkdSessionDriver.swift` (what
happens on connect and disconnect), `MobilinkdLevelAssistant.swift`,
`KISSLinkBLE.swift` and `KISSLinkSerial.swift` (transports), and
`Settings/MobilinkdSettingsSections.swift` (the settings page).

The command set comes from the firmware source, checked out as the
`tnc4-firmware` submodule (`Core/TNC/KissHardware.hpp` and `.cpp`). Mobilinkd's
own configuration apps for iOS, Android and Python (all Apache-2.0) were read
for protocol details and setup wording; no code was copied from them.

## Connecting

Over Bluetooth LE AXTerm recognises a TNC4 by its service UUID
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

The settings page (a radio's settings, under Transport) shows:

- The TNC4's model, firmware, serial number and battery.
- Receive audio: a live level meter, input gain and twist, and "Find the right
  gain".
- Transmit audio: output level and twist, and test tones.
- Radio interface: PTT style, modem type, TX delay, persistence and slot time.
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

The firmware's own auto-adjust isn't used. It saves its result to flash,
changing the TNC4 for every radio, and it loops forever if the input clips at
gain 0 (`AudioLevel.cpp`).

### Test tones

A test tone keys the radio and holds it keyed until it is stopped. AXTerm asks
before sending one and stops it after 10 seconds regardless. The output level
can be changed while it plays. Mobilinkd advises keeping output gain at 64 or
below for a handheld, whose mic input expects very low levels.

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

| Input gain | Pinned at full scale | Back inside the range | Centred again |
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
test: while transmitting, the input sat quiet near centre, and by +1.5 s it
was back to normal noise, centred, with nothing pinned and no drift. Two node
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
restore, the level assistant and the profile migration.

`TNC4SerialLiveTests.swift` does the same over USB and is skipped unless
`TEST_RUNNER_AXTERM_TNC4_USB=1` is set. On 2026-09-29 it confirmed the session,
applying and restoring settings, measuring, and a five-minute receive
(38 packets). When the cable was pulled mid-session, the link noticed at once,
retried with backoff, and was back and decoding about 16 seconds later.

Not yet tested on hardware: Bluetooth on iOS, where the link also stops when
the app goes to the background.
