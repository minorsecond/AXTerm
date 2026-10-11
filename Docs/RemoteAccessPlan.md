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
  QR code. Home sends a fresh challenge, and the device signs the challenge,
  home's callsign and the command text together. A recorded signature cannot
  be replayed or attached to another command. AXTerm does this without the
  operator typing anything.
- From a plain terminal: a six-digit time-based one-time code (TOTP, RFC 6238)
  from an authenticator app on the operator's phone, typed with the command.
  Each code is accepted once. It cannot be tied to the command text the way a
  signature is, so a code is used up by one command, and the commands that
  send or delete something ask for a fresh one.
- Either way: failed attempts slowed down and capped, every owner command
  logged and shown at home, and owner commands off until the operator turns
  them on.

What owner commands may do: mailbox-style traffic (messages, files, status).
Nothing that changes how the station transmits (frequency, power, beacons,
modes). That would be telecommand of the station, which Part 97.213 puts on an
auxiliary-station control link with its own frequency limits.

Rules, as understood (not legal advice): 97.113(a)(4) prohibits messages
encoded to obscure their meaning. A signature or one-time code hides nothing:
the command is in plain text and anyone can read it. Winlink's secure login, a
challenge and response with a hashed password, has been used on the amateur
bands every day for years on the same reasoning. The scheme, like AXDP itself,
should be published before wide use; 97.309 allows data techniques whose
technical characteristics are publicly documented, and the exact wording
needs reading before release.

## Progress

- Pages of long output with `OP n`: done (`dd42661b`).
- Owner sign-in with a one-time code, and `ST`: done.
- XID marker: built and switched off until interop tests pass (`163b2fae`).
- Binary as text: `DB` sends any file up to 64 KB as base64 in the marked
  download form, and AXTerm rebuilds it. 7PLUS waits until its format can be
  read from its documentation rather than written from memory.
- Key-pair sign-in from another AXTerm: done.
- AXDP through a node relay: done. Conversations are routed by the far
  station, PING and PONG name their sender, and completion requests back
  off (AXTERM-TRANSMISSION-SPEC.md, "AXDP through a node relay").
- Still to do: incoming NET/ROM circuits with AXDP over them, the digi path
  test on the air, 7PLUS (needs its source), pushing a file on from home (an
  open question).

## Order

1. Today's fixes first (constitution retest 2026-10-11, findings 1 to 5).
2. Part 1 step 1: test the digi path.
3. Part 2: the terminal-friendly shell, then signing in and owner commands,
   then 7PLUS.
4. Part 1 step 2: AXDP through a node relay.
5. Part 1 step 3: incoming NET/ROM circuits, with AXDP over them.
