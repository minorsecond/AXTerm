# Live traffic on the map

Two answers to "what is happening on the channel right now", both on the map
page so watching it does not mean leaving the map.

## The activity ring

A station that transmitted within `MapActivity.window` (15 s) wears a thin ring
in its own tint, just outside its dot.

**"Currently transmitting" is not observable and this does not claim to be it.**
A packet burst is over in a fraction of a second; by the time a frame is decoded
the station stopped keying long ago. What the receiver knows is when it last
heard someone, so the ring means *transmitted just now*.

Why 15 seconds: recency across minutes and hours is already carried by the dot's
opacity (fresh solid → old faded). The ring answers a different question — who is
on the air *now* — and a longer window would blur the two until most of the map
was permanently "active".

Why a ring and not a pulse: markers on this map are animation-free on purpose, so
that a marker that moves means the station moved (see `StationDotAnnotationView`
and `StationClusterAnnotationView`). An animated pulse would spend that
stillness on decoration, and on a channel carrying a frame every few seconds it
would leave the map blinking continuously.

Why the station's own tint and not one alarm colour: the ring says *when*; the
dot's colour already says *what*. A second hue would claim a meaning it has not
got.

### Expiry

The ring has to go out by itself when the channel falls quiet, or the last
station to speak stays lit for as long as nothing else arrives — precisely the
wrong answer. It cannot ride the ordinary map update, because on a quiet channel
there is not one. `OfflineBasemapMapView.Coordinator` runs a 5-second timer that
calls `StationDotAnnotationView.setActive` on each marker, touching that one
layer and nothing else.

`SiteAnnotation.lastHeard` is deliberately **not** part of `absorb`'s redraw
comparison: it changes on every frame, and a full reconfigure per packet is the
marker churn that class spends most of its length avoiding.

## The traffic strip

A collapsible strip along the bottom-left of the map: the newest frames, one
line each — time, from → to, digipeaters actually used, and what the frame said.
Clicking a line selects that station on the map, which is the reason to have the
two together. Its open/closed state is remembered (`map.traffic.expanded`).

Closed, the header still shows the newest `from → to`, so it does not have to be
open to be useful.

`MapTrafficFeed` is its own `ObservableObject`, and that is the whole point. The
map view is expensive and the engine's packet array changes several times a
second; a view that observed the engine directly would re-render the map for
traffic it does not draw. The feed republishes a short, pre-formatted list at a
400 ms throttle, `MapTrafficChin` observes *that*, and `StationsMapView` holds
the feed as a plain reference it never observes.

It is deliberately not a second Terminal: no search, no selection state, no
scrollback past `MapTrafficFeed.capacity`. The Packets and Terminal pages exist
and are better at all of it; more here would be a worse copy of them competing
for the same screen.

### One radio is one channel

A station with an APRS radio and a packet radio is watching two different
channels, and a strip that pooled them attributed frames to a channel they never
appeared on: hiding the AX.25 radio on the map hid its dots and its traffic kept
scrolling past regardless.

The strip is therefore always scoped. With one visible radio it names that radio
in the header and shows only its frames; with several there is a tab each plus an
**All** tab (`map.traffic.radio` remembers the choice). "Visible" is the same set
the map uses — enabled, and not hidden in the radio list — so hiding a radio
hides its traffic with its stations.

`MapTrafficScope.shows(radio:selected:visible:)` is the whole rule, pure and
tested. A frame with no radio attribution (stored before radios existed, or
synthetic) is shown in the pooled view and claimed by no tab: dropping it would
empty the strip on a station that has only ever had one radio.

### Both directions

Our own transmissions never enter `PacketEngine.packets` — that array is what was
*heard*, and a frame we sent is only heard if something repeats it — so a strip
built from it alone showed a busy channel and no sign of the operator's own
beacon, which is usually the frame they are watching for.

`PacketEngine.onFrameTransmitted` fires at hand-off to the radio (not at
completion: "we keyed" is the event, and a queued KISS write's callback can be a
long way behind the air), and `MapTrafficFeed.record` merges it into the same
time-ordered list. Received and sent are kept in separate arrays so a fresh batch
of received frames cannot discard the transmissions merged in between them. Our
own lines carry a `TX` mark and the accent tint.

### Addressed to us

A row tinted with the accent colour is a frame this station should answer.
`TrafficAddressing.isForUs` asks two different questions because packet radio
puts the addressee in two different places: the AX.25 destination (answered by
`AX25SessionManager.answers`, which covers our callsign, other radios' and
service SSIDs) and, for APRS, the message payload — an APRS message rides a
tocall like `APZAXT` that names the *software*, not the recipient. Bulletins
(`BLN…`) and general queries go to the whole channel and are deliberately not
"for us": tinting them would tint most of the strip.

### Resizing

Dragging the strip's top edge moves an accent line drawn *over* the map, and the
height is written once on release. The strip is a sibling of the map, so every
intermediate height resized the map view — MapKit re-projects, re-anchors every
annotation and re-fits its camera on each one — and the map and everything on it
lurched for the length of the drag.

Only digipeaters with the has-been-repeated bit set are named. An unused entry
is a request, not a path taken, and printing it would claim a route the frame
never travelled.

The feed starts with `.task` on the map, not at launch, so it costs nothing
until the map is opened; `absorb` fills it from the engine's log immediately.

## Tests

- `MapActivityTests` — the window, never-heard, clock skew, and which sites light.
- `MapTrafficFeedTests` — newest first, the tail cap, used-digipeaters-only,
  frames with no printable payload, one-line flattening, own-traffic marking,
  transmissions merged in time order and surviving a fresh received batch, and
  a hidden radio's traffic staying hidden.
- `MapTrafficScopeTests` — tabs are exact, unattributed frames, the pooled view.
- `TrafficAddressingTests` — AX.25 destination, APRS message and ack addressees,
  bulletins and position reports.
- `PacketEngineTransmitTextTests` — what a transmitted frame's one line says.
