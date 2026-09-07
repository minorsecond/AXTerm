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
derived from the decoder's HDLC activity, not the radio's squelch. **No
audio plays until the PTT controller confirms**; the transmitter unkeys
when the device has consumed every rendered sample plus the latency
margin; a watchdog forces PTT off after `maxTransmitSeconds`. Receive is
muted while keyed and for 50 ms after (the codec's TX-time audio is not
the on-air signal).

**Telemetry** (`ModemTelemetry`, ≤10 Hz off the audio thread): peak and
RMS level, clipping, carrier, PLL lock and jitter per slicer, frames
decoded / FCS failures / duplicates suppressed, PTT, queue depth, frames
sent, under- and overruns, audio format and latency. It reaches the radio
form's meter and status rows through `LinkSession → RadioManager →
ConnectionTransportViewModel`, and PTT and carrier transitions go to the
link debug log.

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
