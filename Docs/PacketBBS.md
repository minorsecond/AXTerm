# The Personal Mailbox

A packet BBS that lives in an app, on a Mac that sleeps.

---

## 1. What it is, and what it deliberately is not

AXTerm answers calls with a mailbox: a caller connects, reads bulletins and
mail addressed to them, leaves a message, looks somebody up in the directory,
and disconnects. The command set follows FBB's personal mailbox, because every
packet operator already knows it and nothing about this is worth learning
twice.

It is **not** a forwarding partner, and it does not advertise itself as one.
Other BBSs schedule forwarding against their partners and expect them to be
there; an address that exists only while a Mac is awake would poison their
retry queues, and they could not tell "asleep" from "bad path". That is why
the greeting is not an FBB SID: those capability letters announce forwarding,
and announcing forwarding this does not do is an invitation to schedule
against it.

It is not a NET/ROM node offering transit either, for the same reason with
worse consequences — neighbours would propagate routes through an address that
stops existing.

## 2. The ephemerality question, answered

**When AXTerm is not running, nobody can connect.** That is the whole answer.

It is how every personal packet mailbox has always worked, and packet
operators are entirely used to calling a station and getting nothing back.
Availability is disclosed, not engineered around:

- The operator types their hours into the greeting banner. The app does not
  infer them, predict them, or measure them.
- On quit and on system sleep, open sessions get a closing line and a DISC
  rather than silence. Vanishing mid-session is the expensive failure: the
  caller's software retries into an address that stopped existing.
- **On iPhone and iPad the same rule fires when the scene leaves `.active`.**
  iOS suspends an app that leaves the screen and takes the socket to the TNC
  with it, so backgrounding is this platform's system sleep — and it happens
  many times a day rather than once a night. The shell drives it: an
  `onChange(of: scenePhase)` away from `.active` calls
  `BBSService.shutdown(reason:)` and then `detach()`, and coming back to
  `.active` calls `attach()` and `syncServiceAddress()` again. Leaving it to
  the socket dropping would have every caller's session end as a dropped link
  — the marker in the callers log that is supposed to mean something went
  wrong.

Nothing is lost while the mailbox is down. Messages are in SQLite and
immutable once delivered (CLAUDE.md §7); a caller during the gap simply cannot
reach it, and tries later.

## 3. Layers

```
inbound SABM
      ↓
AX25SessionManager.answers()   — is this address ours at all?
      ↓
SessionCoordinator.addInboundSessionSubscriber
      ↓
PersonalBBSListener            — should *we* answer it?
      ↓
AX25SessionManager.claimDelivery — exclusive byte tap
      ↓
BBSService                     — line assembly, idle timer, transcript
      ↓
BBSShell                       — the command interpreter (pure)
      ↓
BBSMessageStore                — messages, white pages, who called
```

`BBSShell` performs no I/O: lines in, lines and `Effect`s out. That is what
lets the command set — including the visibility rules, which are the part
worth being sure about — be tested against string arrays with no TNC and no
database.

## 4. Several services on one radio

A node runs a mailbox, a Winlink listener and the operator's own terminal at
once, and packet radio separates them the only way it ever has: **by the
callsign the caller dialed.** Give each service its own SSID and they do not
interact.

That requires the station to accept calls on more than one address.
`AX25SessionManager` keeps a registry — `setServiceAddress(_:for:)` — and
`SessionCoordinator` drops any frame not addressed to one of them. **A service
that does not register is unreachable however carefully it is configured**,
which is exactly the failure this was built after: the mailbox had its own
callsign setting and the inbound filter still compared against the station
callsign alone, so a mailbox on its own SSID never saw a single call.

The registry is keyed by service, not held as a set, so editing an SSID moves
the address rather than adding one. A stale registration would leave the
station answering as a service that has moved.

The mailbox registers only **while on air**. Registering always would have
AXTerm answer a SABM and then say nothing, which is worse for the caller than
no answer: they cannot tell connected-to-nothing from merely slow.

## 5. Answering

`PersonalBBSListener` decides, and every refusal explains itself. A station
that silently ignores callers is indistinguishable from a broken one, and the
operator is the person who has to tell them apart.

| Decision | When |
|---|---|
| `answer` | armed, addressed to us, nobody else being served |
| `notArmed` | the default — see below |
| `addressSharedWithWinlink` | Winlink P2P answers the *same address* |
| `identityContested` | another device holds this callsign on this TNC |
| `wrongCallsign` | the call was for somebody else |
| `busy` | a caller is already being served |

**Off by default.** Answering means transmitting with nobody present, which in
the US is automatic control. The operator arms it; shipping it on would make
that decision for them.

**Winlink P2P is a different service, not a competitor.** Both have their own
listen callsign (Settings → Winlink and Settings → BBS), and with different
SSIDs both run at once. They collide only when *both* answer the address that
was dialed — which happens when a listen callsign is left empty and falls back
to the station callsign the other one also uses. Then nothing can tell what
the caller wanted, because the answering station speaks first in both
protocols. The refusal names the fix:

> ignored — Winlink P2P also answers as K0EPI-7. Give the mailbox its own
> SSID (Settings → BBS) and both can run at once.

Checked *after* the callsign match, so a call meant for somebody else says so
instead of blaming Winlink for a conflict that is not why it went unanswered.

**Contention is checked before the callsign matches**, exactly as in
`WinlinkP2PListener`: if a second device already answers as this callsign, a
*matching* call is precisely the problem.

**One caller at a time.** Channel courtesy, but also correctness: the shell
tells a caller "Message 12 stored." *before* the row exists, which is only
sound while nothing else can claim 12 first. `SQLiteBBSMessageStore.store`
throws `messageNumberTaken` if that ever fails, rather than silently
renumbering and leaving the caller quoting a number nobody can see.

## 6. The command set

```
H / ?      help                     W          file areas
L          list readable messages   W <area>   what is in one
LM / LB    your mail / bulletins    WN         what is new since your last call
LL n       the last n               D <name>   fetch a file
R n        read message n           U          send a file to the sysop
RM         read all your unread     A          stop a listing or transfer
S CALL     send mail                I          about this station
SB         post a bulletin          I CALL     directory entry for CALL
K n        kill a message           WP         the whole directory
KM         kill your read mail      J          stations heard here
B          disconnect               N/NQ/NH/NZ tell us about you
V          version
```

**The letters are FBB's**, because a caller who has used packet before should
not have to learn a second dialect: `V` is version, `W` is the file directory,
`I <call>` is a white pages lookup, `A` aborts, `U` uploads. Where a mnemonic
spelling is common elsewhere it is kept as an alias — `F`/`FILES` for `W`,
`FN`/`NEW` for `WN`, `VER` for `V` — so a caller who guesses is not told they
guessed wrong.

`S CALL @ BBS` is accepted, with or without spaces around the `@`. The
mailbox does not forward, so the message is filed under the callsign alone and
the `@BBS` half only teaches white pages (§8).

Every listing is bounded and says what it left out — a listing that stops
without saying so reads as "that is all there is".

`KM` kills only mail the caller has **already read**. A caller who types it
before reading must not discover they destroyed something they never saw.

## 7. Visibility — the whole access model

```swift
func isReadable(by caller: String) -> Bool {
    killedAt == nil && (isBulletin || isAddressed(to: caller))
}
```

One expression, on purpose. It is the only thing between a caller and the
sysop's private mail, and it should be checkable at a glance by someone who
does not trust it.

- **Bulletins are not a separate kind.** A bulletin is a message addressed to
  `ALL`. Kinds crossed with audiences is where mailbox software historically
  leaks private mail — every new kind is another chance to forget a case.
- **Addressing is by base callsign.** Someone calling in as `K0XYZ-7` collects
  mail addressed to `K0XYZ`. Not politeness: a sender has no way to know which
  SSID the recipient will next call from.
- **"Not yours" and "does not exist" are byte-identical.** If `R 7` said *not
  found* and `R 8` said *not authorized*, a caller could map the whole mailbox
  by number without reading a word. `BBSShellTests` asserts the two responses
  are equal.
- **Killing.** A caller may kill their own mail and anything they wrote,
  including a bulletin they posted — but not somebody else's bulletin, which
  would let any caller quietly remove a notice meant for everybody.

## 8. White Pages

A directory of operators: name, location, home BBS, postcode.

White Pages is the oldest piece of shared infrastructure in packet radio and
the easiest to get wrong, because it mixes two very different kinds of fact:
what an operator **told** you, and what you **worked out** from their traffic.
A name is always the former. A home BBS is usually the latter, guessed from a
`@` in a message header.

Keeping them apart is the whole design. Every field carries its own source and
timestamp:

| Source | Meaning |
|---|---|
| `selfReported` | the operator typed it at the prompt, or the sysop typed it in the app |
| `licenceRecord` | the callsign directory AXTerm already caches |
| `fromMessage` | carried in a message this station handled |
| `observed` | derived from traffic |

`WhitePagesEntry.replaces` is deliberately **not** last-writer-wins:

- Stronger source always wins.
- Weaker source never wins, however recent. A guess made this morning must not
  overwrite something the operator typed last year.
- Equal source: newer stands, because people move and rename.
- **Only the operator can clear a field.** Inference falling silent must not
  delete testimony.

A caller may only describe **themselves** — `N` takes a name, never a
callsign. Letting it take one would make the directory writable by anyone who
can key a radio.

### Four fields, and deliberately only four

| Field | Command |
|---|---|
| Name | `N` |
| Location | `NQ` |
| Postcode | `NZ` |
| Home BBS | `NH` |

This is the classic White Pages record every FBB mailbox has published for
decades, and the reason to stop here is the medium. Packet is unencrypted
broadcast: anything `I <call>` prints is heard by everyone in range with a
receiver, logged by anyone who cares to, and cannot be taken back. A street
address, a phone number or an email is a different class of thing from a town
and a callsign — and a mailbox that offers to collect them is inviting people
to put them on the air.

Those three were briefly collectable, kept private to the sysop. That was the
wrong shape of answer: the safe way to hold sensitive data on a broadcast
medium is not to hold it. **A field that is never asked for cannot be
leaked.** Migration v22 deletes any rows that were stored under them, because
data outliving the decision to stop keeping it is the whole problem in
miniature.

### First-call registration

A caller this station has not met is walked through the four public fields
before reaching the prompt, the way FBB does:

```
I have not met you before. Press Return to skip anything.
Your name: Bob
Your town and state: Denver, CO
Your postcode: 80202
Your home BBS (if you have one):
Thank you.
```

Return skips a field; `A` leaves the whole thing at once, because a caller who
did not want to be interviewed should not have to press Return four times to
escape.

### Where entries come from without anybody typing

**The licence record.** AXTerm already keeps a callsign directory
(`CallsignLookupService`, off by default for its own privacy reasons), and a
licence answers exactly two of the four fields: a name, and a town and state.
Those merge in as `licenceRecord` — above anything guessed from traffic,
below anything the operator was told. So a caller who says to call them Bob
stays Bob, and a location guessed from nothing gets replaced by a real one.

Only those two fields are taken. A home BBS is a packet fact and a postcode is
a mailing detail; filling either from a licence would put something weakly
related into a field people read as fact.

**Looked up from cache only, never over the network.** The mailbox answers
calls unattended, and resolving a caller the moment they connect would tell a
third party who is talking to this station. The operator can fill the
directory deliberately — *Fill From Licence Records* in the Directory pane —
which covers everyone who has ever called, not just whoever is on now.

**From BBS sessions the operator has anyway.** When the operator connects to
another BBS in the terminal, its output arrives regardless — and a lot of it
is directory-shaped. `BBSDirectoryHarvester` reads two unambiguous forms out
of it:

1. **`CALL @ BBS`** — the FBB convention for a home BBS, and the highest-yield
   thing in a session: one message listing names a dozen operators' at once.
   Adjacency is the whole signal, so no column layout is assumed.
2. **`CALL  CALL.#REGION.STATE.COUNTRY.CONTINENT`** — the `I <call>` reply on
   FBB and BPQ. The hierarchical address *is* the home BBS field on a real
   network — it is what goes after the `@` to route mail to somebody — so it is
   kept whole rather than taken apart. Splitting out "CO" would trade the
   useful string for a worse one. Anchored on the first component being a
   callsign, which is what stops `winlink.org` qualifying.
3. **`Label: value`** under a subject callsign — what a white pages reply looks
   like on most systems, and what AXTerm's own `I` prints.

Anything else is left alone. A parser that tries to understand every BBS's
output will be wrong somewhere, and wrong here means a false fact about a real
person.

The distinction that makes this reasonable: **nothing asks another system for
anything.** Querying a neighbouring BBS to harvest its database would spend
their channel on our convenience. Reading structure out of bytes that arrived
because the operator went there themselves costs nobody anything, and throwing
it away is waste.

Findings are announced in the **console**, because the operator who just typed
the command is looking at the terminal rather than at the mailbox — a finding
surfaced only where they are not is a finding they never see — and the BBS
sidebar item carries a count.

They are **offered, not applied** — they appear in the Directory pane with
the line each was parsed from, because an operator judging a guess about
another system's format needs to see what was actually read. Accepted ones
land as `observed`, the weakest provenance, so they can never overwrite
testimony or a licence record. Nothing already held with better provenance is
even offered.

**Node tables, from the same sessions.** A node's `N` reply is a table of
`ALIAS:CALLSIGN` pairs — its whole view of the network in one command, where
beacons name one station at a time and only when they happen to transmit.
`NodeAliasParser.parseNodeTable` reads it straight into the alias directory
AXTerm already keeps, persists and syncs. An alias is a fact about identity:
`DRLNOD` is `KE0NCQ` regardless of who said so, which is why
`Docs/UnifiedMailbox.md` classes `nodeAlias` as syncable.

Which half of a pair is the callsign is decided by *shape*, not position —
BPQ's own prompt is the pair the other way round (`K0EPI-7:DRLNOD}`), and a
parser that trusted the order would record every node's prompt as an alias
pointing at the wrong station. A pair where both halves look like callsigns is
skipped rather than guessed.

**What a route table is not.** A node's `R` reply carries *its* neighbours with
*its* quality figures — measured from that antenna, in that place, by that
software. Merging those into AXTerm's own link metrics would assert that
somebody else's measurement is ours, which is the exact thing
`WinlinkLinkQuality.appliesHere` exists to prevent and CLAUDE.md §8 forbids by
requiring metrics be packet-derived. Route tables are good *topology* evidence
and bad *quality* evidence, and the two must not be folded together.

**What is still not possible.** FBB and BPQ distribute white pages as messages
between forwarding partners. This mailbox does not forward (§1), so nobody
will send it those updates.

Between registration and the licence directory, most entries fill themselves.

> I do not have your name — tell me with  N Your Name

Provenance is on the face of the UI row, not buried in a tooltip, because it
decides whether an entry can be trusted. A name someone typed and a home BBS
guessed from a header look identical once you write them both down as text.

## 9. Append-only

`K` sets `killedAt`. Nothing issues a `DELETE` except the sysop's explicit
purge from the app. A killed message is hidden from callers, shown struck
through under the **Killed** filter, and restorable — which is what makes
killing the wrong number survivable.

## 10. What the operator sees

Every decision about files — which folders are shared, what each file is
called and described, whether uploads are accepted and where they land — is in
one place, the **Files** tab of the BBS window, beside the files themselves.
Settings → BBS holds what the *station* does: on air, identity, greeting,
heard list, idle timeout. Splitting them the other way would put the upload
switch somewhere the operator cannot see the folder it fills.


Three things a hardware mailbox cannot show its sysop:

**Reachability, unmissably.** The header answers "can anyone reach me right
now" without reading. The state that matters is not on/off but *on versus off
for a reason you did not choose* — Winlink holding the same address, another
device holding the callsign. Those refusals appear in the operator's own view
rather than being discovered later from a caller complaining.

**The live session.** The caller's transcript as it happens, both directions.
It is also the fastest way to find out a banner reads badly or a command
confuses people: you watch somebody hit it.

**The callers log.** The operator is asleep for most of what the mailbox does.
"W0ARP, 03:12, 2:10 — read 7, left mail for K0EPI" is the question a sysop
actually has, and the message list cannot answer it: a caller who reads a
bulletin and leaves nothing behind is invisible there and perfectly visible
here. Calls that ended with a dropped link are marked, because a caller who
said `B` got what they came for and one whose link dropped may not have.

The Settings pane previews the greeting **using the real shell**, so the
preview cannot drift from what is transmitted.

### Every mailbox you run, in one list

Each device runs its own mailbox, and each keeps its own numbering: "Message 12
stored." is a promise one mailbox made to one caller, and no other mailbox may
reuse it. So what the other instances hold travels here **attributed, never
merged** — filed in its own tables (`remote_bbs_messages`, `remote_bbs_calls`,
keyed by device *and* the originating mailbox's own number), listed in its own
section under that mailbox's name, and never folded into this station's log.

An **Other mailboxes** chip above the Messages and Callers lists brings them
in. Off by default and remembered: an operator reading their own callers log
should never meet a row from another station by surprise. It appears only once
something has arrived — a control for data that has never come is a promise the
screen cannot keep — and stays visible while it is on so it can always be
switched off. The chip carries no `.explain`; the explanation sits on each
remote section's attribution line, beside the rows it describes.

Rows from elsewhere are **read-only**, and the reason is the same one that
keeps the tables apart:

- Reading one **marks nothing**. That mailbox's read flag records what its
  operator did there, and this device cannot know.
- **No kill and no restore.** A kill is that mailbox's append-only history
  (§9); killing from here would invent a state the station that made the
  promise knows nothing about.
- **No unread dot** — a badge nothing here can clear teaches the operator to
  stop reading badges.
- **Reply is allowed**, because it writes nothing there: the reply is composed
  in *this* mailbox, addressed to whoever wrote the original.

Every remote row carries "From K0EPI-9's mailbox on iPad" on the row itself,
not only in the section heading — a row is what gets read and remembered — and
opening one shows that line again over the message with "Recorded by that
mailbox; read-only here." The count line under the list says the split:
"4 messages · 2 from other mailboxes". Which actions a row offers is decided in
one place, `BBSMessageActions.forRow(message:origin:sysop:)`, so a new surface
cannot grow a Kill button over somebody else's history by forgetting a
condition.

Sharing is the *other* device's decision: "Share my packet mailbox" under
Settings → Winlink → Unified mailbox. A device that has not switched it on
publishes nothing, and a device with nothing to read from shows no chip.

### On iPhone and iPad

`BBSScreen` is the same four panes, in two placements the shell chooses between
with `presentation:`.

**`.tab`** (the default, and what an iPad uses) is a `NavigationSplitView`:
sidebar of panes, a list, and a detail. It owns that navigation, so the shell
places it directly as a tab's content — a split view nested in a
`NavigationStack` renders as one squeezed column under two navigation bars.

**`.pushed`** is one `List` inside a stack the shell owns, for the compact
"More" screen, whose own navigation controller would otherwise give every page
two back buttons. Same content, same order: reachability, the live call, then
the four panes as links.

Reachability rides the **content column**, not the sidebar and not above the
split view. Both of those were tried and both hid it: `columnVisibility = .all`
is a request iPadOS declines in portrait — at 834pt three columns do not fit,
so the sidebar goes behind a toolbar button whatever the binding says, taking
the on-air switch with it — and anything placed above the split view is drawn
underneath the floating tab bar. The middle column is the one that is always on
screen, and the switch that decides whether the station answers at all belongs
where the operator opens the page, not one tap into a drawer.

Three things are deliberately different, and only three:

- **Lists, not tables.** A `Table` in the narrow content column of a split view
  draws its first column and nothing else, which for the message list would be
  a page of blank rows over a mailbox holding mail. Rows are purpose-built and
  stack what the Mac spreads across columns.
- **Explanations are tapped, not hovered.** Everything the Mac says through
  `.help()` is said here through `.explain()`, which is a tooltip where there
  is a pointer and a tap-to-reveal popover where there is not. `.help()`
  compiles on iOS and renders nothing, so porting it as-is would have deleted
  every explanation on the platform where the operator is most likely to be
  standing in a field (CLAUDE.md §11).
- **Sheets and importers are singular.** Reply is offered in the reader and New
  Message in the list, but there is one compose sheet, held by `BBSScreen`:
  two `.sheet` modifiers on one view leave only the last one working, silently.
  The Files screen picks a shared folder and an upload inbox through one
  `fileImporter` for the same reason — what the folder is *for* is state, not a
  second presenter.
- **Links are destination links, never `NavigationLink(value:)`.** The shell
  pushes the mailbox into a `NavigationStack(path:)` typed to its own settings
  route, and a typed path accepts only that type: a value link carrying a
  `BBSPane` compiles, draws, highlights when pressed, and appends nothing. The
  row just does not push, with no error anywhere.
- **An explanation never wraps a control.** `.explain` puts its content in a
  container of its own, and on iOS that stops a `Toggle` responding at all —
  the on-air switch drew correctly, its popover worked, and the mailbox could
  not be put on the air. Explanations hang on captions and labels, which are
  inert; a control gets an `accessibilityHint` instead.

Everything else is the same code. The decisions both platforms make — which
messages count as yours, what a caller who left nothing is called, what a file
costs on the air, what a field's provenance reads as, the greeting preview —
live in `BBSMailboxModels.swift`, unguarded and tested, because two platforms
deciding separately what the sysop's mail is would be two chances to get the
access model wrong and only one of them ever looked at.

Settings → Mailbox (`BBSSettingsScreen`) holds exactly what the Mac's settings
tab holds, including the live greeting preview. Shared folders and uploads stay
in the mailbox's own Files pane on both platforms, for the reason above: the
upload switch belongs beside the folder it fills.

## 11. Bounds, because this runs unattended

- Message body: 100 lines / 8 KB, **refused rather than truncated** — a caller
  whose message was silently halved believes it arrived whole.
- Every listing capped, and it says how many rows it did not show.
- Idle disconnect, operator-selectable, default five minutes.
- Transcript capped at 500 lines in memory.
- A call left open by a crash is closed at its *connect* time on next launch,
  not at "now" — stamping now would invent a caller who stayed for three days.

## 12. Privacy

`J` publishes what this receiver has heard. On by default: a heard list is
standard on a BBS, a mailbox that refuses one reads as broken, and the
stations in it are transmitting on the same channel the caller is already
listening to. It does say what this antenna reaches, which is a rough
statement about where the operator is, so it can be switched off — and then it
says so rather than returning an empty list.

## 13. Tests

- `BBSShellTests` — the original six commands, weighted toward visibility.
  Getting `L` to line up costs an afternoon; letting a caller read the sysop's
  mail costs the operator's trust in the feature.
- `BBSShellCommandsTests` — the directory, listings and bulk forms.
- `BBSWhitePagesTests` — the merge rule, case by case.
- `BBSDirectoryHarvesterTests` — weighted toward *not* finding things: email
  addresses, `TO @ ALL`, unknown labels and labels with no subject all yield
  nothing.
- `PersonalBBSListenerTests` — answering the calls that are ours, refusing
  every other one legibly, and sharing a radio with Winlink P2P.
- `StationServiceAddressTests` — which addresses the station accepts at all.
- `BBSFileIndexTests` — resolution, traversal attempts, and the size/time
  rendering the whole file UX rests on.
- `BBSFileCommandsTests` — browsing, `WN`, text-as-text, the long-transfer
  confirmation, and that the command letters match FBB.
- `BBSUploadPolicyTests` — the gates, and the filename, which is the part a
  stranger chooses.
- `BBSMailboxModelsTests` — what the operator's own views decide: which
  messages a filter shows, what counts as unread, how a call with no actions is
  described, the airtime beside a file, a field's provenance caption, and that
  the greeting preview is byte-for-byte what the shell transmits.
- `BBSFileLibraryTests` — sharing a folder end to end against a real one on
  disk: flat, no symlinks, no hidden files, the size cap, descriptions that
  live in the database rather than in the operator's folder, and an inbox that
  is counted but never served.
- `SQLiteBBSMessageStoreTests` — promised message numbers, kill/restore,
  read-flag monotonicity, the call log, file areas, last-visit, and the white
  pages merge rule as the store applies it.

## 14. Files

### What a caller sees

The listing is itself a transfer, so it has to earn its bytes. Every row
carries the one number that decides anything:

```
NAME              SIZE  TIME  ABOUT
netscript.txt       4K    1m  Tuesday net preamble
roster.txt        143K   28m  Duty roster, Q3
```

**TIME, not SIZE, is the column that matters.** "143K" sounds small and is
twenty-eight minutes of a frequency somebody else also wants. The figure comes
from measured throughput rather than a nominal baud rate — 1200 baud is 150
B/s of raw channel and nearer 90 B/s delivered once framing, acks and sharing
the air are paid for. An estimate that flatters itself is worse than none,
because a caller plans around it.

`F` alone lists areas with counts and totals. `F <area>` lists one.

**`FN` is the listing a regular caller actually wants** — what is new or
changed since they were last here, taken from their previous row in the call
log. Sending the whole catalogue every visit spends airtime telling somebody
what they already know, and the catalogue is the part they stop reading.

Descriptions are the operator's, held in the database rather than beside the
files: the shared folder belongs to them and nothing here writes into it. A
filename alone tells a caller nothing, and on this link they cannot afford to
download one to find out what it is.

### Getting a file

**`D <name>` is the only command a caller needs**, and it picks the cheapest
way to deliver:

- **Text under 8 KB is sent as text.** No protocol to negotiate, nothing the
  caller has to have, and fewer bytes than any framing would cost. Most of
  what a packet file area holds is text, so this is the common path rather
  than the fallback.
- **Everything else runs a transfer** — **AXDP** when the caller has answered
  a capability probe (compression, resume and selective retransmit are all
  airtime saved) and **YAPP** otherwise, because that is what every other
  packet terminal on the band actually implements.

Above five minutes of estimated airtime, `D` quotes the cost and waits to be
asked again. Confirmation is per file, so agreeing to one does not agree to
the next. Asking once costs a line; finding out forty minutes in costs the
frequency. `A` stops it.

While a transfer runs it owns the session's byte stream; the line assembler
gets it back when the protocol finishes.

### Uploads

`U` arms the receiver; the protocol is recognised from the caller's own first
bytes, so they use whatever their software speaks.

**Off by default, separately from downloads.** Sharing files out and accepting
files in are different decisions with different risks, and this one writes to
the operator's disk on the say-so of whoever is holding a microphone.

**Uploads land in their own folder and are not served.** Deliberately not one
of the shared areas: a caller who could write into an area would be publishing
to every other caller the moment the transfer finished — using the operator's
station to distribute something nobody had looked at. They sit in the inbox
until the operator moves them.

`BBSUploadPolicy` decides, from the transfer's header, before a byte is
written:

| Refused when | Default |
|---|---|
| uploads are off, or no inbox is set | off, unset |
| the file is empty, or larger than the limit | 100 KB — twenty minutes of channel |
| the inbox is already full | 20 MB |
| this call has uploaded too many already | 3 |
| the filename survives sanitising to nothing | — |

The filename is the dangerous part, so `sanitize` is a **whitelist**: strip to
a leaf, refuse `.`/`..`, strip leading dots so no dotfile can be created, map
anything outside ASCII letters, digits and `._- ` to an underscore, cap at 64
characters keeping the extension, and refuse a name with no letter or digit
left in it. ASCII only — a name a stranger chose is rendered back to the
operator, and lookalike characters are not worth accepting for a filename on a
packet link.

**Uploads never overwrite.** A caller replacing a file the operator already
has is a way to change what the station serves, so a collision becomes
`name-2.ext`, matched case-insensitively because the filesystem usually is.

Every upload is named in the call log. An unattended station accepting files
is exactly what an operator wants to read about afterwards.

### Safety

A file area exposes part of a filesystem to anyone who can key a radio, so the
guarantee is structural rather than defensive:

**`BBSShell` has no filesystem access at all.** `BBSFileLibrary` scans the
shared folders into an index of basenames, and `D`/`V` resolve what the caller
typed **by lookup in that index** — never by joining their input onto a path.
`../../etc/passwd` is a name that matches nothing, rather than a string that
has to be sanitised correctly. `BBSFileIndexTests` asserts this for a spread of
escape attempts.

Scanning is one level deep, files only. Symlinks are not followed — a link
inside a shared folder is a way to serve something the operator never chose to
share. Hidden files are skipped, and so is anything over 5 MB.

The app is sandboxed, so each area keeps a **security-scoped bookmark**.
Without one the area would work until the operator quit and then quietly serve
nothing.

## 15. Known limits

- **The mailbox answers only while AXTerm is running**, and on iOS only while
  it is in the foreground (§2). Both platforms have the whole mailbox: the
  shell, the service, the store and the white pages model were always
  platform-neutral, and `AXTerm/BBS/UI` now holds a Mac window (`BBSView` and
  its panes), an iOS screen (`BBSScreen` and its panes) and the shared models
  and views both use.
- **No forwarding, by choice** (§1). White pages are learned locally and never
  exchanged with other BBSs, which is the other half of that decision.
- **Areas are flat.** Subfolders are not scanned, which keeps `D <name>`
  unambiguous without teaching a path syntax over a link where the caller
  cannot see what they are typing.
- **The sysop replies from the app, not over the air.** There is no remote
  sysop mode, and adding one would mean authenticating a caller as the
  operator — a real design problem, not a missing button.
