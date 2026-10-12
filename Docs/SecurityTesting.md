# Security testing

AXTerm lets its operator sign in over the air and change the station: radio
power, frequency and mode through rigctld, and scripts the operator writes.
This document covers what an attacker on the channel can do about that, the
tests that try it (`AXTermTests/Security/`, SEC-1 to SEC-39), what they found,
and the risks that remain.

Run the suite with:

```
xcodebuild test -project AXTerm.xcodeproj -scheme AXTerm -destination 'platform=macOS' \
  -only-testing:AXTermTests/SecurityOwnerCodeTests -only-testing:AXTermTests/SecurityOwnerCallsignTests \
  -only-testing:AXTermTests/SecurityOwnerKeyTests -only-testing:AXTermTests/SecurityOwnerCodeStateTests -only-testing:AXTermTests/SecuritySessionHijackTests \
  -only-testing:AXTermTests/SecurityControlInjectionTests -only-testing:AXTermTests/SecurityControlLinkTests \
  -only-testing:AXTermTests/SecurityFailSafeTests -only-testing:AXTermTests/SecurityFileNameTests \
  -only-testing:AXTermTests/SecurityBoundsTests
```

The tests run with the rest of the unit suite as well. None of them
transmits or opens a radio.

## Threat model

The attacker has a radio on the channel. They hear everything the operator
and the station send, and they can send any AX.25 frame under any callsign,
including the operator's own. They cannot read the station's Keychain, the
operator's paired device or its Secure Enclave, or the authenticator app.

Amateur rules forbid encryption, so nothing on the air is secret. Every
defense is authentication: proving a line came from the operator without
hiding what it says.

What the attacker wants, in rough order of harm:

1. Make the station transmit: key it, send CW or DTMF, or play a voice memory.
2. Change the station: power, frequency, mode, or whatever an owner script
   does.
3. Read the station's state (`ST`), meant for the operator only.
4. Keep the operator out by locking up the sign-in.
5. Get something unpleasant sent on the air under the station's call, such as
   terminal escapes or a huge echo.
6. Write files outside the inbox, or grow the station's storage without bound.

## The defenses

- **Who may try.** Only the operator's base callsign, at any SSID, is offered
  `OWNER` at all. To anyone else, `OWNER`, `ST` and every control command are
  unknown words (SEC-5). The callsign proves nothing, since anyone can send it.
  It only keeps the commands out of other people's sight.
- **Code sign-in.** A six-digit TOTP code, accepted once. A code is good for
  two minutes after it appears, enough to cross several digipeaters, and one
  30-second step early for a slow station clock. Three wrong codes lock codes
  out for 15 minutes. Each later lockout, with no right code between, is twice
  as long, up to a week (SEC-1 to SEC-4). The last code used and the lockout
  are kept in preferences, so a restart changes neither, and the operator can
  see and clear a lockout on the Remote Control page (SEC-36 to SEC-38). A
  code sign-in reads the station and never changes it (SEC-18), because
  nothing on the operator's end can add a per-command check, and a code
  cannot be tied to the command it rides with.
- **Key sign-in.** From a paired AXTerm, ECDH P-256 against a one-time key
  the station sends with its challenge, with HKDF over both callsigns. The
  answer is a 128-bit check. One answer per challenge, and a challenge goes
  stale (SEC-6 to SEC-12). The lockout on codes never applies to a key, so
  someone sending wrong codes all day cannot keep a paired device out.
- **Each command checked.** Signed in by key, every owner command carries
  `!xxxxxx`, a 32-bit HMAC over a counter and the command text, under the
  session's key. Three wrong checks end the sign-in (SEC-13 to SEC-17). 32 bits
  is enough here because a guesser gets three tries per sign-in, and each
  sign-in costs a fresh key exchange the attacker cannot answer.
- **What a command can do.** The operator sets up each command. Arguments are
  plain numbers of at most 16 characters, or one word from a list (SEC-19).
  Radio power takes the radio's own range in watts (SEC-20). Nothing that
  keys the transmitter or hands the radio raw commands is accepted (SEC-21).
  A script is a file name in the scripts folder, never a path (SEC-22). Radio
  and script output is cleaned before it goes on the air (SEC-23).
- **Where a change may come from.** Only a direct link on a frequency where
  97.201 allows an auxiliary station: 2 m and up, outside the satellite and
  weak-signal segments. A digipeated link, a NET/ROM circuit, or a link
  whose frequency AXTerm does not know cannot change the station
  (SEC-24, SEC-25).
- **Fail-safe.** A change goes back when the link fails or after 150 seconds
  without a frame from the operator, inside the 3 minutes 97.213(b) allows.
  Changes go back newest first. A failed restore is logged as failed. Other
  stations' traffic does not count as hearing the operator (SEC-26 to SEC-29).
- **Bounds and records.** Received and uploaded file names cannot leave their
  folder (SEC-30, SEC-31). Paging, echoed input and the remote-control log are
  bounded (SEC-32 to SEC-34). Every attempt, right or wrong, at every door, is
  logged with who, where, and the path it came over (SEC-35, SEC-39).

## Test map

| SEC | Class | What is attacked |
|---|---|---|
| 1 | SecurityOwnerCodeTests | Guessing the code: lockout holds against the right code; a year at the fastest allowed pace stays under 0.15%; a right code resets the escalation |
| 2 | SecurityOwnerCodeTests | Replaying a heard code, or an older one after a newer |
| 3 | SecurityOwnerCodeTests | A code more than two minutes late or more than one step early |
| 4 | SecurityOwnerCodeTests | Look-alike digits, signs, spaces, other lengths |
| 5 | SecurityOwnerCallsignTests | Other callsigns trying `OWNER`, `ST` and control words |
| 6 | SecurityOwnerKeyTests | Replaying a key sign-in on a new challenge; a second answer to one challenge |
| 7 | SecurityOwnerKeyTests | A sign-in made for another station or another caller |
| 8 | SecurityOwnerKeyTests | An unpaired key |
| 9 | SecurityOwnerKeyTests | Truncated, padded, re-cased and garbage answers |
| 10 | SecurityOwnerKeyTests | A stale challenge |
| 11 | SecurityOwnerKeyTests | Invalid public-key encodings |
| 12 | SecurityOwnerKeyTests | Answer comparison (see the note below) |
| 13 | SecuritySessionHijackTests | An owner command injected into the signed-in session with no check |
| 14 | SecuritySessionHijackTests | Forged checks |
| 15 | SecuritySessionHijackTests | Replaying a heard check |
| 16 | SecuritySessionHijackTests | Moving a check onto another command or argument |
| 17 | SecuritySessionHijackTests | A check from another session |
| 18 | SecuritySessionHijackTests | Changing the station after a code sign-in |
| 19 | SecurityControlInjectionTests | Smuggling text through number and choice arguments |
| 20 | SecurityControlInjectionTests | Impossible radio power |
| 21 | SecurityControlInjectionTests | Keying the transmitter or sending raw radio commands |
| 22 | SecurityControlInjectionTests | Scripts outside the scripts folder |
| 23 | SecurityControlInjectionTests | Escapes and control characters in radio or script output |
| 24 | SecurityControlLinkTests | The excluded segments, at their edges, and below 2 m |
| 25 | SecurityControlLinkTests | Unknown frequency, digipeated link, NET/ROM circuit |
| 26 | SecurityFailSafeTests | The silence limit against 97.213(b) |
| 27 | SecurityFailSafeTests | Restore order |
| 28 | SecurityFailSafeTests | A failed restore reported as done |
| 29 | SecurityFailSafeTests | Holding the fail-safe off with another station's traffic |
| 30 | SecurityFileNameTests | Path tricks in received file names |
| 31 | SecurityFileNameTests | Path tricks and odd characters in upload names |
| 32 | SecurityBoundsTests | Absurd page lengths |
| 33 | SecurityBoundsTests | A 100,000-character line at the mailbox and the node |
| 34 | SecurityBoundsTests | Growing the log without bound |
| 35 | SecurityBoundsTests | Unlogged attempts |
| 36 | SecurityOwnerCodeStateTests | Replaying a heard code after a restart |
| 37 | SecurityOwnerCodeStateTests | Ending a lockout, or its escalation, by a restart |
| 38 | SecurityOwnerCodeStateTests | The lockout shown and cleared at the station; clearing it logged; a used code stays used |
| 39 | SecurityOwnerCodeStateTests | Wrong codes logged with the digipeaters or circuit they came through |

SEC-12 checks that `OwnerKey.matches` gives the right answers. The timing
property comes from its code, which compares every byte and ORs the
differences, and the test does not measure time.

## Results, 2026-10-12

The first run had 11 failures. Six were mistakes in the tests, fixed in the
tests. Five were real, and each one
was fixed with its failing test as the first step.

| SEC | Finding | Fix |
|---|---|---|
| 1 | The 15-minute lockout let a patient guesser try about 93,000 codes a year, a 28% chance of getting in. | Each lockout after the first doubles, up to a week, until a right code. About 180 guesses a year at most. |
| 19 | A number argument could be any length. | At most 16 characters. |
| 21 | The keying rule looked only for `T` and `set_ptt` split on spaces, so `T<tab>1`, `b`/`send_morse` (CW), `\send_morse`, `w`/`send_cmd` (raw CAT), `send_dtmf` and `send_voice_mem` got through. | The first word is split on any whitespace, and the short letters `T b w W` and the long names, with or without the backslash, are all refused. |
| 23 | Radio and script output went on the air as-is: terminal escapes, BEL, NUL, backspace, bidirectional overrides. | Escape sequences and control characters are removed, tabs become spaces, before lines are cut to length. |
| 33 | An unknown command was echoed back whole, so a 100,000-character line went back on the air. | The echo is cut to 16 characters at the mailbox and at the node. |

After the fixes, all 42 security tests pass, along with the full unit suite
(9,935 tests, integration tests excluded because they transmit) and the iOS
build.

Later the same day, after a review with the operator:

- Codes were good for 30 to 60 seconds after they appeared, too little for
  reading, typing and several digipeater hops with retries. They are now good
  for two minutes. Each guess can match six codes instead of three, so a year
  of guessing at the fastest pace the lockout allows went from about 0.06% to
  about 0.11%. The bar in SEC-1 moved from 0.1% to 0.15% to match, a choice
  made for usability.
- The checker's memory was in memory only. A restart ended a lockout and,
  within two minutes of a code sign-in, let the heard code be used again. It
  is kept in preferences now (SEC-36, SEC-37).
- The operator can see and clear a lockout on the Remote Control page
  (SEC-38), and wrong codes are logged with their path (SEC-39).

All 48 security tests pass after these changes, with the full unit suite
(9,941 tests) and the iOS build.

## Accepted risks

- **AX.25 is unauthenticated.** Anyone can send frames into the operator's
  session under the operator's callsign. Owner commands need a valid check,
  so this cannot change the station. Ordinary mailbox commands (reading,
  listing, sending mail) have no check and can be injected, as on any packet
  BBS.
- **Mailbox users do not sign in** (decided 2026-10-12). RF mailboxes know a
  user by callsign; a password typed on the air would be heard by everyone.
  Anyone sending another station's callsign can read its mail, as on any
  packet BBS. A mailbox reached over telnet will ask for a password.
- **A code sign-in has no per-command checks.** It is used once and only
  reads the station, but someone who hears it can inject `ST` or a read-only
  control command into that session until it ends. Use a paired key for
  anything that changes the station.
- **The lockout can be used against the operator.** Someone sending wrong
  codes on purpose can keep code sign-in shut for up to a week. A paired
  device's key still signs in, the operator can clear the lockout at the
  station (and over telnet once it exists), and the log shows each attempt
  with its path. Keeping it shut takes days of transmitting the operator's
  callsign, which is deliberate interference on record.
- **Owner scripts are the operator's own code.** AXTerm controls which file
  runs and what arguments it gets. What the script does is up to its author.
- **Fail-safe timing depends on frames.** A link that stays up with the
  operator silent is caught by the silence limit. A station that crashes
  or loses power cannot run the restore at all.
