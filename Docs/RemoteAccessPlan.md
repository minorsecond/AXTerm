# Reaching home AXTerm from the road

Plan, not yet built (operator, 2026-10-11). The operator is away from home
with a radio and wants to reach the AXTerm at home: send it a file, fetch one,
or use it, over one or more hops that are plain AX.25 digipeaters or NET/ROM
nodes. Two parts: AXDP across those hops, and a text interface for when the
station on the road cannot speak AXDP at all.

Nothing here changes how AXTerm behaves on plain AX.25. It changes where AXDP
may go, who AXTerm treats as the other end, and what the mailbox offers a
caller who types.

## Part 1: AXDP across digipeaters and nodes

AXDP is bytes inside ordinary I-frames (PID 0xF0). A digipeater repeats a
frame by its address and never reads the contents, and a NET/ROM node relays
a circuit's bytes without reading them either (YAPP already works through
BPQ, so binary gets through). The work is in AXTerm, in three steps.

### 1. Over a digipeater path, as it is

This should mostly work now: the session, the in-session capability check and
the UI probe all follow the session's digi path. AX.25 acknowledges end to
end, so a frame lost on any hop is resent across every hop, and a digipeater
on the same frequency halves the throughput for each hop it adds. AXDP's
compression cuts what the digipeaters repeat, and its own acks and resume
ride on top.

To do: a test over a real one-hop and two-hop path, with the route's learned
K and paclen and the transfer's timing in the log. Fix what that shows; no
design change expected.

### 2. Through a node relay (`C K0EPI-2` at the node prompt)

AXTerm ties AXDP to the station at the other end of the radio link, and here
that is the node. Needed:

- AXDP addressed to the far end of the relay, with frames going to the node
  link. The terminal already knows the relay's far end
  (`relayConversation`).
- The capability check held until the node reports the connection to home,
  then sent inside the session, so the PING never reaches the node's prompt.
- The far end's answer cached under its own callsign, not the node's.
- Timers that allow for the extra hops: the transfer's waits taken from the
  round trip it measures, not from a direct link's.

### 3. Native NET/ROM circuits to home

The best version. NET/ROM retries hop by hop, so a loss is repaired on the hop
where it happened, and AXDP's end-to-end acks confirm the file arrived whole.
AXTerm already opens NET/ROM circuits (`Docs/NetRomTransport.md`). Not built:

- Accepting an incoming circuit at home. Today AXTerm refuses them ("Not yet
  built" in `Docs/NetRomTransport.md`).
- AXDP over a circuit. It only uses ordinary AX.25 sessions now.
- The capability check and transfers keyed to the circuit's far end.

## Part 2: a text interface that works well

Often the station on the road will not run AXTerm: a handheld's built-in TNC,
a phone app, a borrowed station, or a node circuit that carries only lines of
text to the mailbox. The home AXTerm should be pleasant to use from a plain
terminal.

What exists: the mailbox's FBB-style shell (`Docs/PacketBBS.md` section 6),
which a caller reaches directly or through the node. Over a circuit it can
only type out text files under 8 KB; `D` of anything else and `U` are refused.

Every kind of caller must work well (operator, 2026-10-11): another AXTerm,
a plainer terminal such as QtTermTCP, and bare text. So each feature has a
form a typist can use, and AXTerm adds what it can do automatically.

- Owner commands, where they can be made safe (operator: yes). When the
  caller is the operator, more of AXTerm through the shell: what is waiting,
  stations heard, recent transfers, a file pushed on to another station, a
  message left for home. A callsign on AX.25 proves nothing, so each owner
  command carries proof. See "Signing in" below.
- Binary as text, for links that carry only lines. 7PLUS is what packet
  software has used for this for decades and many terminals decode it; base64
  is the fallback any computer can decode. Both cost more airtime than the
  file itself (base64 a third more), so offer them only where YAPP and AXDP
  cannot go.
- A terminal-friendly shape for every reply: lines under 80 characters, no
  tabs or escape codes, long output in pages with "Enter for more, A to stop",
  every listing saying what it left out, and the prompt saying what can be
  typed next.
- AXDP features named in plain words. A caller who types gets the same
  results in text: "D photo.jpg" offers 7PLUS when YAPP cannot run, "WN"
  shows what arrived by AXDP since the last call, and so on.

### Signing in

Proof, never secrecy: every command and reply stays readable by anyone
listening, and the proof is extra characters next to it. The operator accepts
a sign-in for owner commands.

- From AXTerm: a key pair per device. The private key stays on the device (on
  iPhone and iPad, in the Secure Enclave, which holds P-256 keys); the home
  station keeps the public keys of the devices paired with it, in person, by
  copy and paste. `OWNER KEY` gets a one-time public key from home, and both
  ends derive the same session key from it (ECDH, then HKDF over both
  callsigns) without the key going on the air. The device proves it holds
  its key with one full 128-bit check (`OWNER MAC`, 22 characters). After
  that each owner command carries a 32-bit check over a counter both ends
  keep and the command's text, `!a8F3kQ ST`: 8 characters, where a signature
  took about 150. A command heard on the air cannot be sent again (the
  counter has moved on) or moved to another command, and three wrong checks
  end the sign-in, so a forger gets three tries at 1 in 4.3 billion. LTE and
  5G guard their control messages the same way, with a 32-bit check and a
  counter. Someone sending wrong checks can only make the operator sign in
  again, and never lock the key out. AXTerm adds the checks without the
  operator typing anything.
- From a plain terminal: a six-digit time-based one-time code (TOTP, RFC 6238)
  from an authenticator app on the operator's phone, typed with the command.
  Each code is accepted once. It cannot be tied to the command text the way a
  signature is, so a code is used up by one command, and the commands that
  send or delete something ask for a fresh one.
- Either way: failed attempts slowed down and capped, every owner command
  logged and shown at home, and owner commands off until the operator turns
  them on.

What owner commands may do: mailbox-style traffic (messages, files, status)
now. Changing how the station transmits (frequency, power, beacons, modes) is
telecommand of the station. 97.213 allows it over a radio control link that is
an auxiliary station (97.201: 2 m and up, outside 144.0-144.5 and 145.8-146.0
MHz, so 145.650 qualifies) or over a wireline link, which includes the
internet. The station must stop transmitting within 3 minutes if the control
link fails, must be protected against unauthorized transmissions, and must
have the license and a contact label posted at the station.

Rules, as understood (not legal advice): 97.113(a)(4) prohibits messages
encoded to obscure their meaning. A signature or one-time code hides nothing:
the command is in plain text and anyone can read it. Winlink's secure login, a
challenge and response with a hashed password, has been used on the amateur
bands every day for years on the same reasoning. The scheme, like AXDP itself,
should be published before wide use; 97.309 allows data techniques whose
technical characteristics are publicly documented, and the exact wording
needs reading before release.

### Owner control commands

The operator defines control commands in Settings › Remote Control, which
also holds owner sign-in and the paired devices: they control the whole
station, and the node offers them as well as the mailbox. Each one has:

- a word to type (1 to 8 letters and digits, not one of the mailbox's own),
  and a help line that `H` shows to the owner;
- a rule for what follows the word: nothing, a number between a lowest and a
  highest, or one of a list. Nothing else reaches the action, so a typed line
  cannot smuggle a second rigctl command or shell text into it;
- an action: a line sent to a Hamlib rigctld (`{arg}` stands for what
  followed the word; Warbler serves the IC-705 on `localhost:4533`), or, on
  the Mac, a script in AXTerm's Application Scripts folder, the one place a
  sandboxed app may run the operator's scripts from;
- whether it changes how the station transmits;
- a scale and a unit. Hamlib gives power as a fraction of the radio's full
  power, so 0.5 on the IC-705 is 5 W, not half a watt. With a scale of 10 and
  the unit W, `SETPWR 5` sends `L RFPOWER 0.5` and `PWR` answers `5.0 W`. The
  fail-safe still puts back exactly the value the radio reported.

Radio commands name the radio after the word, so one word serves every
radio: `PWR 705` reads the IC-705's power, `PWR 710 50` sets the FT-710 to
50 W. Each radio is set up once under Radios for control commands on the same page, with a
short name, its rigctld, its power range in watts, its full power (what
Hamlib's RFPOWER 1 means on it) and how many steps it keeps power in. A
power outside the radio's range is refused before anything reaches it
(`PWR: the 705 takes 0.5 to 10 W.`). Hamlib and Warbler truncate when they
turn the fraction into the radio's steps, so 0.5 on the IC-705 became step
127 of 255, which the radio shows as 49%. AXTerm picks the nearest step to
the watts asked for and sends a value a quarter step above it, which lands
on that step whether the far end truncates or rounds. A radio can be kept
to reading from the road.

Add the Radio Set adds QRG, MODE, PWR, SIG and VOLTS, and names Warbler's
IC-705 (`705`, localhost:4533, 0.5 to 10 W) and FT-710 (`710`,
localhost:4532, 5 to 100 W) if no radios are set up. Only power can be set:
retuning the IC-705, or switching it out of FM, would cut the link the
command came in on. The FT-710 runs the station's HF link unattended, so a
power change there reaches that link too; turn its "can be changed from the
road" off to keep it to reading.

A command that changes how the station transmits:

- needs a key sign-in: a code is not tied to the command it comes with;
- runs only on a direct link (no digipeaters, not through a node) on a
  frequency where 97.201 allows an auxiliary station;
- reads the current value first (or names a script that puts it back), and
  is refused if it cannot, so the fail-safe always has something to run;
- is put back when the link fails, or when nothing is heard from the operator
  for two and a half minutes, inside the 3 minutes 97.213(b) allows. Hanging
  up on purpose keeps the change.

A control command may never key the transmitter (rigctl `T` or `set_ptt`):
nothing could promise to let go of it. The mailbox names its owner commands at
sign-in (`Owner commands: ST QRG MODE PWR SIG VOLTS`), so the device knows which lines
get a check without being set up at its end. Every run, every refusal and
every step of the fail-safe goes in the call log.

## Progress

- Pages of long output with `OP n`: done (`dd42661b`).
- Owner sign-in with a one-time code, and `ST`: done.
- XID marker: built and switched off until interop tests pass (`163b2fae`).
- Binary as text: `DB` sends any file up to 64 KB as base64 in the marked
  download form, and AXTerm rebuilds it. 7PLUS waits until its format can be
  read from its documentation rather than written from memory.
- Key-pair sign-in from another AXTerm: done. Each owner command carries a
  32-bit check under a session key from ECDH (8 characters per command).
- Owner control commands (rigctl and scripts) with the fail-safe: done.
- AXDP through a node relay: done. Conversations are routed by the far
  station, PING and PONG name their sender, and completion requests back
  off (AXTERM-TRANSMISSION-SPEC.md, "AXDP through a node relay").
- Incoming NET/ROM circuits with AXDP over them: done. A circuit caller
  that speaks AXDP leaves the node prompt for a conversation; outbound
  circuits carry AXDP to their station.
- Still to do: the digi path test on the air, 7PLUS (needs its source),
  pushing a file on from home (an open question).

## Order

1. Today's fixes first (constitution retest 2026-10-11, findings 1 to 5).
2. Part 1 step 1: test the digi path.
3. Part 2: the terminal-friendly shell, then signing in and owner commands,
   then 7PLUS.
4. Part 1 step 2: AXDP through a node relay.
5. Part 1 step 3: incoming NET/ROM circuits, with AXDP over them.
