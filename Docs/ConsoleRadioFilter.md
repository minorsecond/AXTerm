# Hiding a Radio in the Terminal

What the per-radio sidebar switch hides in the console, and what it must not.
`ConsoleLine.Subject`, `ConsoleLine.passesRadioFilter`.

## The rule

Three checks, in order:

1. **Errors always show.** Hiding a radio is a *view* filter, not an
   operational disable. The radio is still on the air with our callsign on it
   whether or not we are looking at it, and we answer for what it transmits. A
   link that drops, a PTT that is refused, a port that is lost has to reach the
   operator from a hidden radio exactly as from a visible one.
2. **App notices always show**, because no radio owns them. A migration, a
   settings change, an app lifecycle event is not any radio's business and
   there is nothing for the filter to match it against.
3. **Everything else belongs to its radios** and hides with them: a received
   frame, one we sent, a link coming up, a reply heard, a beacon.

## The distinction that matters

Not system-versus-packet. Whether a **radio owns the line at all**.

`radioID` used to be nil for two unrelated things — "the app is talking" and
"we do not know which radio" — so the filter could not tell them apart and
resolved it by showing every system notice whatever was hidden. A two-radio
station with one switched off still read that radio's connects, disconnects,
transmissions and beacons.

`Subject` makes it explicit:

| Case | Means | Filter |
|---|---|---|
| `.app` | the app itself | always shows |
| `.radios([id…])` | one or more named radios | shows while any is visible |
| `.unnamedRadio` | a radio, but we cannot say which | hides with the primary |

`.unnamedRadio` follows the primary because that is what `PacketFilter` and the
map already do with an unattributed packet (`packet.radioID ?? .primary`) — so
a line whose attribution was lost hides with something rather than slipping
past the filter unnoticed.

## Shared TNCs

A link can carry several radios: a shared TNC demultiplexes them by KISS port
onto one byte stream (`Docs/SharedTNC.md`). That link coming up is news for
every radio on it, so the notice is attributed to all of them and survives
while **any** is visible. Picking one of them to name would be a guess, which
is also why the per-line radio badge stays blank for those lines —
`ConsoleLine.radioID` returns a radio only when exactly one owns the line.

`RadioManager.radios(carriedBy:)` is the reverse lookup.

## Our own transmissions are not exempt

They were, and it put this view at odds with the Packets table, which has
always hidden them with their radio. It also produced half a conversation: hide
a radio and you saw what you sent on it but not the answer that came back.

The safety argument for the old behaviour — that an operator should always see
their station transmit — is answered by rule 1 instead. Failures are never
hidden, and nothing is destroyed either way: the Packets table, the session
history and the database still hold everything.

## Attributing a line

```swift
addSystemLine("Connected to \(endpoint)", category: .connection,
              radios: radioManager.radios(carriedBy: link))
```

Attributed so far: link connect and disconnect, `Frame sent successfully` (from
`frame.radio`), and the beacon notices, which already named their radio in the
prose and now follow it as well. Everything else stays `.app` and behaves as it
did — the filter checks the subject first, so each emitter converted starts
working on its own and there is no flag day.

A caller that knows its radio should say so:

```swift
packetEngine?.appendSystemNotification(text, radio: radioID)
```

Left out, the notice is the app's and shows whatever is hidden.

## Persistence

`ConsoleEntryMetadata.radios` stores the attribution, so a reloaded transcript
hides with the same switches a live one does. Absent means `.app`, which is
also how every line written before this reads — the right answer for the system
notices among them, and for the packet lines it matches the attribution they
already lost on reload.

## Tests

`AXTermTests/Unit/UI/ConsoleLineRadioFilterTests.swift` — each rule, the shared
link, the badge, the round trip, and the two behaviours this deliberately
changed (own transmissions, radio-scoped notices).
