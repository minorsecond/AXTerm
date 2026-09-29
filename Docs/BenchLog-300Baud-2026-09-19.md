# Bench log: proving the 300 baud HF path, 2026-09-19

Warbler had four transmit tickets closed (`#4` packet transmission from the UI,
`#29` connected-mode AX.25, `#27` station ID on transmit, `#15` packet mailbox)
and nobody had ever held a two-way packet contact with it. This is what came out
of a day spent finding out why.

The short version: Warbler's 300 baud modulator is the fault. Everything else in
the chain was eliminated by measurement.

## Result

| direction | signal at the receiver | frames | decoded |
|---|---|---|---|
| Warbler modulator -> FT-710 -> IC-705 -> AXTerm | S9, 32 dB in-band SNR | ~50 | 2 (4%) |
| AXTerm modulator -> IC-705 -> FT-710 -> Warbler | ~11 units over noise, level 26 | 1 | 1 (100%) |
| Direwolf audio -> Warbler's `/api/tx` -> FT-710 -> IC-705 -> AXTerm | — | 3 | 3 (100%) |

The third row is the one that localises it. Direwolf's audio was streamed into
Warbler's push-to-talk WebSocket, so it went out over the same SCU-LAN10
session, the same radio, the same air path and into the same receiver — and
decoded completely. The only thing swapped out was who generated the samples.

AXTerm transmitted into a **dummy load** at a level barely above the noise and
Warbler read it first time. Warbler transmitted a full-strength signal into a
receiver 32 dB out of the noise and it could not be read.

## What the received audio measured

Captured at the point AXTerm's demodulator reads it, so after the audio device,
the channel selection and the network stream:

- tones 1592 / 1792 Hz against an expected 1600 / 1800 — an 8 Hz offset between
  two radios, which is nothing
- shift exactly 200 Hz
- bit rate 300.00 baud
- in-band SNR 32 dB, S9 at the radio
- mark/space twist 0.2 to 0.6 dB
- transport lossless: 48 kHz LPCM, Icom LAN codec `0x04`, no dropouts, no
  splices, no inserted silence
- time spent between the two tones 7%, against 6.5% for a known-good signal

Every averaged property of that signal is correct and it still will not decode.
The recovered bit stream carries the payload text in a consistent repeating
pattern with scattered errors — `west 1` for `test 1`, `0EPI` for `K0EPI` — so
this is structured corruption, not noise.

**Direwolf's `atest` decodes exactly the same 2 frames from the same recording**,
and gets no further with `-F 1`, `-F 2`, `-P E+` or `-D 1`. Two independent
decoders agreeing is what rules out the receiver.

## Where to look in Warbler

The daemon states its wire format as "16 kHz stereo signed 16-bit little-endian,
10 ms per frame", and the packet modem is dwcore, which generates at its own
rate. Something resamples between the two. A resampler that drops or repeats a
sample to hold sync produces timing jitter, and jitter corrupts bits
cumulatively across a frame while leaving the averaged spectrum untouched.

That matches the whole shape of the evidence, including the part nothing else
explained: short frames occasionally decoded, and 128-byte frames never did.

## Ruled out, each by measurement rather than opinion

- **Level and noise.** 32 dB in-band SNR, S9 at the radio.
- **Tuning, shift and clock.** Measured correct to 8 Hz and 0.00 baud.
- **Receiver overload.** S9 is healthy; overload needs 20-30 dB more. (A later
  run with the receiver pegged on the same desk *was* invalid, but the
  measurements above were taken with it across the room.)
- **FX.25.** Off made no difference: 2/31 with, 0/5 without, and identical tone
  discrimination of 0.50 against 0.49.
- **The audio transport.** Lossless PCM, no lost packets.
- **AXTerm's detector filter length.** Swept from 60 Hz to 600 Hz transition —
  16.5 bit periods down to 1.6 — with no change in decode at any setting.
- **The SCU-LAN10 interface and the FT-710.** The bypass run proves both.

## AXTerm defects found

Fixed here, with tests:

- **`RigReceiveAudit` judged every station as 1200 baud FM.** The mode check was
  a literal `.fm`, so a 300 bd HF station was told at blocking severity to
  switch to FM — on 20 m, advice that guarantees the silence it was called to
  explain. The filter check sat in the `else` of that test, so the one setting
  that matters most at 300 bd, where a narrow data filter removes one of the two
  tones, was never reached on the stations that needed it. `ModemMode.expectedRigMode`
  is now the single definition, read by both `configureForPacket` and the audit.
- **Changing the radio's mode was silent.** `setsRadioModeOnConnect` rewrites the
  operator's radio at every connect and said nothing, so setting the sideband by
  hand looked like it had worked until the next reconnect put it back. It now
  says so, and only when it actually changed something.
- **The capture limit was hit in normal use.** Ten minutes ran out during the
  waiting part of a bench session, and the recording stopped before the
  transmission it had been switched on for. An hour now, and it records that it
  stopped.

Open:

- **Terminal Broadcast always transmits on the primary radio.**
  `buildOutboundFrame()` omits the `radio:` argument, so every frame takes the
  `.primary` default, and Broadcast mode has no radio picker to override it. A
  frame composed while looking at a 300 bd HF radio went out on 2 m FM at 1200
  baud, and the UI reported it sent, because it was — somewhere else.
- **`onReceiveDrift` has no consumer.** The link re-audits every couple of
  minutes and calls it; nothing listens, so drift findings only reach the
  operator through the error banner.
- **`linkDidError` is the only operator-visible channel the link has.** A notice
  like "I changed your radio's mode" has to travel as an error.

## Tooling added

- `ModemAudioCapture` — writes the audio handed to the demodulator to a plain
  16-bit mono WAV, off unless `modemCaptureRx` is set. The header is rewritten
  on every flush so the file is readable while the app is still running.
- `CapturedAudioDecodeTests` — reads a capture back through every mode and
  prints frames, checksum failures and peak tone discrimination, which answers
  both halves of "did a signal arrive, and was it the one we thought".
- `CapturedAudioSweepTests` — sweeps the detector filter against a real
  recording. This is what disproved the filter-length theory.
- `TestRig/scripts/warbler_tx_bypass.py` — streams Direwolf-generated audio
  through Warbler's `/api/tx`, putting somebody else's modulator on Warbler's
  radio link. This is what localised the fault.
- `TestRig/scripts/direwolf_tx_bench.sh` — swaps the Direwolf service to another
  baud rate on its own sound card and restores it afterwards. Unused in the end,
  because that DigiRig is on the 2 m node radio rather than the FT-710.

## Wrong turns

Recorded because each cost time and each was wrong for a reason worth
remembering.

- **`audioEnabled`.** Read as the transmit path; it is "Use a sound device", for
  feeding external apps through a local ALSA device. The symptom that prompted
  it — `tx.bytes` reading 0 through a burst that clearly put 51 units of power
  on the air — turned out to be a broken counter in Warbler.
- **Detector filter length.** A good theory with real arithmetic behind it (16.5
  bit periods at 300 bd against 2.5 at 1200) that the sweep flatly disproved.
- **Receiver overload.** Plausible, and ruled out by the S-meter reading S9.
- **"AXTerm has no network sockets."** An `lsof` invocation that ORs `-p` and
  `-i` without `-a`. `netstat` showed all three Icom LAN flows established.
