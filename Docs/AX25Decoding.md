# AX.25 frame decoding

`AX25.checkFrame(ax25:)` in `AXTerm/KISSAX25Decoder.swift` turns the bytes of
one KISS data frame into addresses, control, PID and info, or says why they
are not an AX.25 frame. `AX25.decodeFrame(ax25:)` is the same call with the
reason dropped. Every received frame goes through `PacketEngine.processAX25Frame`,
which calls it once.

## Address rules

A TNC only checks the 16-bit FCS, so with the squelch open about one burst of
noise in 65,536 reaches the app looking like a good frame. Before these rules
the decoder took any printable character as part of a callsign, skipped the
rest, and upper-cased the result, and one such burst became a heard station
called `V},'-11` (2026-09-29). The decoder now applies AX.25 2.2 §3.12 to each
7-byte address:

- Bit 0 of the six callsign bytes must be clear. It is the address-extension
  bit, which only the SSID byte of the last address sets. Direwolf finds the
  end of the address field by the first byte with bit 0 set, so this rule is
  also how Direwolf reads the header.
- Each character, shifted right one bit, must be A-Z, 0-9 or space. Spaces are
  padding and may only trail. A leading space, an embedded space or six spaces
  is refused.
- Lower case is refused. The spec allows upper-case letters and digits only,
  TNC firmware, the Linux ax25 tools and BPQ upper-case callsigns when they
  encode them, and Direwolf rejects a received address with lower case in it.
- The SSID byte is not judged. Bits 5 and 6 are reserved and usually 1, but
  some software sends 0. Bit 7 is the C or H bit and can be anything.
- Bit 7 means "has been repeated" (H) only on a digipeater. On the destination
  and source it is the command/response (C) bit, so the decoded destination
  and source never read as repeated; the frame's `isCommand` carries the two C
  bits instead (true for a command, false for a response, nil when they are
  equal, which is AX.25 1.x). A packet reads its command/response from its own
  raw bytes. Until 2026-10-06 the C bit was stored as `repeated`, and a
  response's source did not compare equal to its station.

Real traffic fits inside these rules: callsigns, APRS tocalls, `WIDEn-N`,
`RELAY`, `TRACE`, `RFONLY`, `NOGATE`, `TCPIP`, `BEACON`, `ID`, `CQ`, `QST`,
`MAIL`, `NODES`, and Mic-E destinations, which encode latitude in 0-9, A-L and
P-Z. NET/ROM node aliases travel in the info field, never in an address.

## Address field rules

The address field is destination, source and up to eight digipeaters, and it
ends at the first SSID byte with the extension bit set. The frame is refused
whole when:

- any address, digipeater included, breaks a rule above (the old decoder
  stopped at a bad digipeater and read its first byte as the control field);
- the destination has the extension bit set, which would leave no source;
- no address sets the extension bit before the bytes run out, or by the 10th
  address;
- nothing follows the address field, so there is no control byte.

`AX25Digipeater` refuses to repeat any frame the decoder refuses. The engine
asks it before decoding, and it walks the path without checking characters.

The NET/ROM parsers (`NetRomTransportWire`, `NetRomBroadcastParser`) read
shifted callsigns out of the info field. They already require A-Z/0-9 with
trailing padding, and they only see frames that passed the rules above, so
they keep their existing tolerance of bit 0.

## Refused frames

A refused frame never becomes a packet or a station. `PacketEngine` logs it
under the parser category as "Failed to decode AX.25 frame" with a reason that
names the address and the byte, for example
`source address: invalid character 0x7D at position 2`, adds a warning
breadcrumb, and sends one throttled Sentry event per kind of fault (see
`Observability.md`).

## Tests

- `AX25AddressValidationTests`: each rule, both ways, and the overnight frame.
- `AX25AddressCorpusTests`: `AXTermTests/Fixtures/ax25-address-corpus.json`,
  155 frames from the test database, the other fixtures and constructed
  connected-mode, NET/ROM and edge cases. Each must decode exactly as the old
  decoder read it.
- `AX25AddressFuzzTests`: seeded property tests. Random bytes, near-miss frames
  and bit flips of the corpus must be accepted exactly when an independent
  Direwolf-style oracle accepts them, and read the same as the old decoder;
  random valid addresses must round-trip through every encoder.
- `MalformedFrameIngestTests`: the engine logs the noise frame and hears
  nobody.

Frames stored before these rules are not re-checked, so a station made from
noise earlier stays in the stored history.
