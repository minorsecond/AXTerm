# AXTerm APRS symbol set

Original artwork. Drawn for AXTerm, owned by AXTerm, no third-party licence
attached — see `axterm-symbol-artwork-licensing` for why that mattered.

## The system

Every rule here exists to make the set read as one family at 20px, which is
the size the map actually draws them.

- **24×24 viewBox, 20×20 live area.** Nothing crosses x/y 2 or 22 except
  deliberate overhangs (house eaves, the HF wire, the overlay plate's ticks).
- **Fill only.** No strokes, no gradients, no opacity, no shadows. Radio waves
  are filled crescents, not stroked arcs — the first draft used
  `stroke="currentColor"`, which resolves to *black* unless the consumer sets
  `color`, and rendered invisible on the map's dark markers.
- **One path per part, `fill-rule="evenodd"`** for holes (doors, windows,
  ladder rungs).
- **Straight geometry sits on the grid.** Integers or halves. Arcs are the
  only place decimals appear, and they come from a polar helper, not by hand.
- **Minimum feature 1.2px** so nothing dissolves at marker size.

### Shared construction

| family | shared line |
|---|---|
| vehicles | wheel centres at y=17.6, ground at 20.5, all face right |
| buildings | body 5..19, eave line, 45° roof |
| infrastructure | mast on x=12, 1.4 wide |
| plates | 12×12 clear centre for an overlay character |

Variants are systemic, not separate drawings: `house-hf` **is** `house` with a
wire; the whole point is that they read as related.

## Coverage

30 icons (plus one colour variant). Measured against the 2026-09-10 capture, with phantom parses
excluded (see below): **99.3% of real position reports**, and the remaining
0.7% is on the fallback layer deliberately.

| file | symbols | meaning |
|---|---|---|
| house | `/-` | House QTH (VHF) |
| house-hf | `\-` | House (HF) |
| box-plate | `\A` | Box (overlay) |
| circle-plate | `/0`..`/9` | Circle 0-9 |
| digipeater | `/#` `\#` | Digipeater — a star with a hollow centre |
| hf-gateway | `/&` `\&` | HF gateway |
| antenna | `/r` | Antenna |
| dish-antenna | `` /` `` | Dish antenna |
| car | `/>` `\>` | Car |
| van | `/v` | Van |
| jeep | `/j` | Jeep |
| suv-atv | `\k` | Special vehicle SUV / ATV |
| truck | `/k` | Truck |
| truck-18-wheeler | `/u` | Truck (18-wheeler) |
| rv | `/R` | Recreational vehicle |
| fire-truck | `/f` | Fire truck |
| boat | `/s` | Ship / power boat |
| bicycle | `/b` | Bicycle |
| person | `/[` | Human / person / pedestrian |
| campground | `/;` | Campground / portable |
| weather-station | `/_` `\_` | Weather station |
| rain-shower | `\I` | Rain shower |
| flooding | `\w` | Flooding |
| blowing-dust | `\b` | Blowing dust / sand |
| hurricane | `\@` | Hurricane / storm |
| gas-station | `\9` | Gas station |
| kenwood-k | `\K` | Kenwood — drawn as a plain letter K |
| mac-apple | `/M` | Mac apple — unbitten |
| unassigned | `/J`, other reserved codes | no assigned meaning |

### Trademarks

`\K` is "Kenwood" and `/M` is the "Mac apple". Both are drawn here, both
deliberately short of the mark itself.

- **`\K` is a plain letter K.** A letter is not a logo. It carries the
  meaning — a Kenwood radio — without reproducing the wordmark.
- **`/M` is an apple with no bite.** The bite is the distinguishing element
  of Apple's mark; without it this is fruit. Stem and leaf are ours.

`mac-apple-colour.svg` is a six-stripe variant, the classic order reversed.
**It needs a colour-capable render path** — the map tints every glyph white
through `APRSGlyphRasterizer`, so on a marker it would come out solid. Use it
where colour survives: the station card, the symbol picker. The mono
`mac-apple.svg` is the one the map draws.

### `/J` is reserved, and in use anyway

KF0YKI-9 beacons `/J` 45 times in this capture, with course and speed, while
the spec leaves the code unassigned. Inventing a pictogram would put a meaning
into the protocol that is not there, so it draws as `unassigned` — a ring and
a dot, which says a symbol arrived and stands for nothing agreed.

### Phantom symbols

The first survey of the capture reported 40 distinct symbols. Seven of them
(`\1 \2 \3 \5 \7 \E \m`, 38 reports) were not symbols at all: Winlink
proposal frames begin `;PM: ...`, and a naive parser reads `;` as an APRS
object report and takes the symbol from the middle of someone's message text.
An object's 9-character name is followed by `*` or `_`; checking that byte
removes them. Worth knowing before trusting any symbol census — including
AXTerm's own.

### `\#` is the digipeater, whatever the spec calls it

The alternate `#` is named "Number (overlay)", so it was first drawn as a
generic plate. That is spec-literal and practice-wrong: the New n-N Paradigm
tells digipeaters to beacon `#` with a letter on it — `S` for a digi honouring
the state alias, `1` for a WIDE1-1 fill-in, `I` for an igate — so `\#` **is**
the digi symbol, and it had the one shape in the set that said nothing about
being infrastructure.

Both tables now draw the star the primary table has always documented:
"DIGI (white center)". The hollow centre is where the overlay letter lands,
so one drawing serves the bare digi and the overlaid one.

A lattice tower was tried first and failed for a measurable reason: the letter
is knocked out of the glyph, and thin splayed legs give it nothing to bite
into. Rendered through the real rasteriser, `S` on a tower was mud and `S` on
a star was crisp.

## Measuring a change

    python3 Design/aprs-symbols/measure.py

Legibility at 18px — the size the map actually draws — is not an opinion.
`measure.py` rasterises the set at that size and reports two numbers:

- **ink coverage.** Median is ~26%. Anything under ~15% disappears against a
  tinted dot; anything over ~40% is a blob. The original APRS icons were
  chunky 15px bitmaps, so mass is faithful to the source, not a departure
  from it.
- **silhouette IoU between every pair.** Two icons that share most of their
  pixels *are* the same icon to a reader. The first vehicle set measured
  0.73-0.81 across car/jeep/truck/van/suv/rv — seven labels on one drawing.
  Each now owns a different share of the box: how tall, how long, how big the
  wheels, and one superstructure the others lack.

**The number is a proxy, not the verdict.** IoU between vehicles is high by
construction — they are all boxes on wheels — and `house`/`mac-apple` measure
0.68 while being obviously different to look at. Two icons that scored *well*
were unreadable: the antenna hit target ink and read as a tree, then as a
capital I. Measure to find candidates, then render and look.

## Reviewing a change

    python3 make_sheet.py && rsvg-convert -w 1320 _sheet.svg -o /tmp/sheet.png

The sheet renders each icon at 4× **and** at 26px inside a tinted dot. Judge
at 26px — three of these looked fine large and failed small (the antenna read
as a spade, the gateway as a barn, the HF house as a dumbbell).

## Wired in

The artwork ships as `AXTerm/Assets.xcassets/APRSSymbols/*.imageset` (SVG,
vector-preserving, template-rendered so the map can tint it). Generated from
this folder — regenerate after editing an SVG:

    python3 Design/aprs-symbols/install.py

`APRSSymbolArtwork` maps a symbol to an asset and works out what character
goes on top; `APRSGlyphRasterizer.image(table:code:diameter:)` draws the
artwork where we have it, SF Symbols where we do not, and composites the
character. `APRSSymbolArtworkTests` pins all of it, including that every
asset name resolves to a non-empty template image — a name that loads nothing
draws nothing, silently.

## Not done yet

- The 158 codes of the 188 that never appeared on this channel. SF Symbols
  answers for them.
- `mac-apple-colour` is in the catalog but unused: the map tints every glyph
  white, so it needs a colour-capable surface (the station card, the picker).
- The SwiftUI call sites — the sidebar row and the own-station marker — still
  draw `Image(systemName:)` straight from `APRSSymbolGlyph`, so they show SF
  Symbols and no overlay. Only the map markers go through the rasterizer.
- `G9` (a letter on a solid gas pump) is the most cramped of the overlays.
  Legible, but it is the one to look at first if the size needs tuning.
