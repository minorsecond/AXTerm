# Node Directory

Every NET/ROM alias this station has learned, in one browsable list —
sidebar **Nodes**.

## What it holds

An alias is a tactical name (`DRLNOD`, `AGNODE`, `YZBBPQ`) with no licence
behind it, so no callsign directory can resolve one. Stations announce them
about themselves and about each other, and AXTerm reads those announcements
where they already arrive:

| Source | Form | Example |
|---|---|---|
| Node tables | `ALIAS:CALL` | `AGNODE:K1AJD-4  ARAPEY:CX2SA-7` |
| ID / beacon frames | `CALL/R ALIAS/N` | `KE0NCQ/R DRL/D DRLBBS/B DRLNOD/N` |
| BPQ node identification | `NODE: ALIAS:CALL, …` | `NODE: YZBBPQ:KB5YZB-7, Aurora, CO` |

Node tables are the highest-yield source by a wide margin: one `N` or `NODES`
to one node names its whole view of the network, where a beacon names one
station and only when it happens to transmit.

## Each row

- **alias → callsign** — the pairing, as announced.
- **service** — `node`, `BBS`, `digipeater`, `gateway`, `relay`. Codes travel
  as single letters and conventions vary between stacks, so an unrecognised
  one is shown verbatim rather than guessed at.
- **via `<station>`** — who told us. An alias is hearsay: `AGNODE` came out of
  KB5YZB-7's table, not from K1AJD-4 itself, and an operator judging whether
  to trust it needs to see that. Entries learned before this was recorded read
  *source not recorded*.
- **last heard** and **heard ×N** — repetition is the only corroboration
  available for a claim no directory can check.

## What a node's table does and does not say

A node's table is a reachability list, not a census. It names BBSes
(`BVJBBS`), chat servers (`BVJCHT`), RMS gateways (`DATRMS`), DX clusters
(`BSADXC`) and nodes (`BVJNOD`) alike, and says nowhere which is which.

So entries harvested from a table carry **no service code**. Stamping them all
`N` made `netRomDeclaration` report a BBS as a NET/ROM node, with the evidence
line "Its identification announced the node alias BVJBBS" — an identification
that station never sent. Alias suffixes usually hint at the role, but a
convention is not an observation, and BPQ conventions vary.

A service code therefore means one thing only: the station's own ID or beacon
announced it, in the `CALL/R ALIAS/D ALIAS/N` form. The Nodes page shows `—`
otherwise. Because most rows come from tables, a label there now carries
information.

Stored entries stamped `N` before this rule are cleared on first launch of a
version carrying the fix. Entries with a teller other than themselves came from
a table; a station's own ID is not a teller, so declared services survive.

## Where the names are used

The directory answers in both directions.

`callsign(for:)` takes an alias and returns the licence behind it. That is the
older direction and it is what puts node traffic on the map: `DRLNOD` is not a
licence and no callsign directory will ever place it, but `KE0NCQ` has a grid
square.

`preferredAlias(for:)` and `aliases(for:)` go the other way. A callsign can hold
several names — one licence running a BBS, a digipeater and a node announces one
name per service — so the plural form returns all of them, node role first,
because the node name is what turns up in via paths and connect targets. The
SSID is **not** stripped in this direction: `KE0NCQ-7` is DRLNOD and `KE0NCQ-1`
is DRLBBS, and folding the SSID away would return one station's services when
asked about another's.

`otherName(for:)` combines the two for displays that hold whichever name the
AX.25 address field carried. It returns nil when nothing is known, and never
echoes back the name it was given. It scans the directory per call, so anything
naming a *list* uses `otherNames()` instead, which builds both directions in one
pass; the two are held to the same answers by test.

Displays that consult it:

- **Stations sidebar** — each row shows the other name in dim monospace beside
  the callsign.
- **Packet inspector** — both ends of the header.
- **Node profile** — the "Also announced as" line, and the note recording which
  name the operator actually tapped.
- **Nodes page** — rows open the profile of the station behind them, addressed
  by alias so the profile can say which name led there.

Aliases are swept out of stored beacons when the Packets, Map or Nodes page is
opened, and learned live from session text as node tables arrive. The sweep runs
off the view-update path.

Connect deliberately does **not** resolve aliases. A BPQ node answers to its
alias as an AX.25 address — NODECALL and NODEALIAS both respond — so `C SOLBPQ`
is resolved by N0HI-7 itself. Resolving it here would duplicate the node's own
job and would be wrong the moment a node's table and ours disagree.

## Why it is not the routing table

Routes (sidebar **Routes**) are evidence that *this* station can reach a
destination, earned from traffic it observed, with df/dr/ETX derived from that
traffic (see `Docs/RoutingAndLinkQuality.md`).

A node's table is a different kind of statement: *that* node's view, with *its*
qualities, mostly about stations this one has never heard. Merging the two
would fill the routing table with destinations nothing here has ever reached
and quality figures nothing here measured — exactly what CLAUDE.md §8 forbids.

So the two live side by side and stay separate. The directory answers "what is
`ARAPEY`, and who says so"; Routes answers "can I get there, and how well".

## Reaching them from the Terminal page

The directory is a route source, not only a page. Two places surface it.

The **`To:` destination picker** lists a *Reachable via nodes* group alongside
Favorites, Recent Heard and Neighbors, each row naming its route — `AGCHAT ·
via KB5YZB-7`. It is offered in every mode, not only NET/ROM: an operator typing
a name is asking "what can I connect to", and answering only once they have
already picked the right mode makes them solve the problem first. Anything
already offered as heard, favourited or a neighbour is left out, since a
better-evidenced route to it exists.

The **Terminal sidebar** carries a matching section above Stations: one line per
node, saying how many stations it reaches, opening them in Nodes. Above, because
thirty heard stations scroll past before it would otherwise appear — the answer
to "what can I reach" sat underneath the list of what was already reachable.

It lists nodes and not stations on purpose. Expanding one node put eighty-five
rows in the sidebar and pushed the navigation itself off the top: the section
meant to orient the operator swallowed everything they were oriented by. The
three surfaces have distinct jobs — the sidebar orients and jumps, the picker
finds a name and connects to it, the Nodes page browses. Duplicating the browse
into a sidebar was the error.

The two lists are deliberately separate, and not for tidiness. A station under
*Stations* was **heard** — this receiver holds its frames. An entry under
*Reachable* is a **claim**: a node published a table saying it can get there,
and nothing here has verified it. They also differ in what you do with them —
one you call directly, the other through somebody. Anything already heard is
left out of the reachable list, since the direct route is better evidenced.

Typing a name works the same way. `ConnectBarViewModel.updateRuntimeData` takes
the directory's `connectRoutes()` alongside the measured `RouteInfo` list and
fills in destinations nothing has measured — keyed by both the alias and the
callsign, since the operator types whichever they last read. Before this, the
connect bar knew only the ten destinations with an observed route and answered
"No known route" for a name the Nodes page had just shown as reachable.

**Measured routes always win.** A claim only ever fills a gap: it never
displaces an observed route, and never replaces a per-hop route seen to work.
The preview says which kind it is — `KB5YZB-7 lists AGCHAT: KB5YZB-7 → AGCHAT`
rather than `Best route:` — because a node's table entry is good enough to try
and is not the same thing as having watched a frame arrive.

Clicking drafts the connect, double-clicking runs it, matching the click grammar
of a heard station. The draft is a NET/ROM connect to the *alias* with the
teller as `nextHopOverride`, which the existing relay executes: L2-connect to
the node, wait for its banner, send `C <alias>`, wait for `###LINK MADE`. The
alias is sent unresolved on purpose — BPQ looks it up in its own table, and
translating it here would fight the node (see "Where the names are used").

## Do not prune by reachability

Nothing in this list is unreachable because of distance. BPQ nodes link over
AXIP/AXUDP, so a node's table names stations on the far side of IP tunnels —
`PY2BIL` (Brazil), `YD0BCX` (Indonesia), `ZL2BAU` (New Zealand) are all
connectable through the node network, and none of them will ever be heard on
RF here. "Never heard on air" is the *expected* state for most of this list,
not a sign of a dead entry.

That makes the directory a reachability list rather than an accumulation: these
are destinations the network says can be reached, and the ones furthest away
are precisely the ones no other source in AXTerm could have discovered.

`tellers` carries the practical half of that: every node that has listed this
station, and when it last did. The node that listed a station is the node to
connect through to reach it — KB5YZB-7 naming `PY2BIL-1` means `C PY2BIL` at
KB5YZB-7 is the route. That is a hint, not a measured route; see the section
above for why it stays out of the routing table.

It is a map rather than a single name for two reasons. Two nodes listing the
same station are two ways in, and an earlier design kept only whichever spoke
last, silently discarding a route. And a node's table is a claim that ages: one
that listed a station an hour ago is a better bet than one that listed it in
June, so `reachableVia` returns tellers newest first — the order to try them in.

A station is never its own teller, and a change of claimed callsign clears the
tellers: what they said was about the old claim.

An entry with no tellers is not junk — resolving `DRLNOD` to `KE0NCQ` for a map
pin or a via-path label needs no teller — but it offers nowhere to connect. The
page says "no route known" and can filter those rows out, because listing them
beside routable ones made 193 names read as 193 places to go when 95 were.
Asking a node for its table (`N`) attributes every station that node knows.

## How the page is laid out

Rows are grouped under the route that reaches them, with a pinned header naming
the node and the count. This is the page's structure rather than a sort option,
because the route is what the operator is looking for and it barely varies down
the list: on one live directory ninety of ninety-nine rows shared a single node.
Printed per row it was a column spent on the least surprising fact on screen,
while the thing that does vary — which stations a given node can reach — had no
shape at all. Entries with no route form the last group.

An entry reachable several ways is filed once, under its freshest route, and
carries a `+n more` marker; repeating it per teller would inflate the counts
that make the sections worth reading.

Everything that was near-constant down the page came out of the row. Service is
an inline badge shown only when the station declared one — fewer than one row in
thirty — because a column empty thirty times over reads as broken data rather
than as absent evidence. Last-heard and announcement count merged into one
relative timestamp with the detail in its tooltip: every row of a single table
pull shares a timestamp, and most claims are heard once.

The station profile carries the same fact as a line under the callsign —
"Connect to KB5YZB-7 and ask for AUGRMS". For a station harvested from a table
that is the only thing the profile knows, and it previously showed a page of
empty sections instead.

The profile's Connect button performs it, and is labelled with the route —
**Connect via KB5YZB-7** — because for a station nothing here has heard, which
node it goes through is the interesting half of the action. One button covers
two different connections: a heard station is called directly, while one that
appears only in a node's table is asked for *through* that node. The alias is
what goes on the wire in the second case, unresolved.

## Forgetting dead entries

The Nodes page can forget entries meeting **both** conditions:

- no teller — nothing has offered a way to reach the station, so there is
  nowhere to connect to get to it; and
- the callsign is unknown to this station — it appears in no packet, no
  neighbour record and no route, at any SSID.

Neither condition alone is a valid criterion. Unroutable entries still earn
their keep resolving names for map pins and via-path labels (`EATON → W2CRS`),
and "never heard on air" is meaningless by itself in a network where BPQ nodes
link over AXIP — most useful destinations are behind IP tunnels and will never
reach this receiver.

Together they mean nothing can be done with the row and nothing else is using
it. The operation is also cheap to be wrong about: if a node lists the station
again it returns *with* a teller, which is the form worth having in the first
place. On one live directory the split was 92 forgettable of 98 unroutable.

It is an explicit action with the count on the button, never automatic.

## Counting announcements

`announcements` counts *separate* announcements of the same alias→callsign
pairing, and is the only corroboration available for a claim no directory can
check.

An announcement counts only when its timestamp is strictly newer than the one
already stored. This matters because stored beacons are re-swept every time the
Packets, Map or Nodes page is opened: without the rule, every sweep re-counted
every beacon still in retention, and a station that beacons often reached
"heard ×1708" — a tally of page visits presented as evidence. The same rule
stops a late-read old frame from dragging `heardAt` backwards, which would make
"Recently heard" sort on when a sweep reached an entry.

Attribution is the one exception. Learning *who* told us is new information even
when the claim is not, so a replayed frame still fills in a `learnedFrom` that
was never recorded. This is what heals rows reading "source not recorded":
they are entries learned before the field existed, not entries of poor quality,
and re-hearing the alias — or re-sweeping the beacon it came from — attributes
them without deleting anything.

Counts written before this rule existed are unrecoverable: each is a real count
plus an unknowable number of re-sweeps. They are reset to 1 once, on first
launch of a version carrying the fix, so the column measures what its tooltip
claims. The alias claims themselves are untouched.

## Where it is stored

`UserDefaults`, key `station.nodeAliases`, JSON-encoded — not the SQLite
database. It is a few hundred short strings; a migration would cost more than
it is worth, and it still survives restarts, which is the part that matters:
an alias learned while the network was up stays resolvable when it is not.

## Parsing notes

Which half of `A:B` is the callsign is decided by **shape**, not position — a
node's own prompt can carry the pair either way round, and trusting the order
would record every prompt as an alias pointing at the wrong station.

When both halves look like callsigns, an SSID breaks the tie: the node's
callsign in these tables carries one and a tactical alias never does. Without
that rule, aliases opening with a digit (`2RZBPQ:VK2RZ-7`, `5EBBS:AE5E-3`)
scored as callsigns on both sides and were silently dropped — two of the
eleven nodes KB5YZB-7 listed on 2026-08-27.
