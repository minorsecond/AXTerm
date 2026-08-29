#!/usr/bin/env python3
"""NET/ROM NODES broadcast encoding, byte-identical to AXTerm's own
NetRomNodesBroadcast/NetRomTransportWire so a farm node's advertisement
is one AXTerm genuinely parses. Validity depends on this matching the
Swift exactly:

    byte 0        0xFF signature
    bytes 1..6    origin alias, plain ASCII, space-padded
    N x 21:
        7  destination callsign  (AX.25-shifted, ssid byte 0x60|ssid<<1)
        6  destination alias     (plain ASCII)
        7  best-neighbour call   (AX.25-shifted)
        1  quality
"""

SIGNATURE = 0xFF
MAX_ENTRIES = 11


def shifted_call(call, ssid, last=False):
    out = bytearray()
    for c in call.upper().ljust(6)[:6]:
        out.append((ord(c) if 0x20 <= ord(c) <= 0x7e else 0x20) << 1)
    out.append(0x60 | ((ssid & 0x0F) << 1) | (0x01 if last else 0))
    return out


def alias6(alias):
    cleaned = [ord(c) for c in alias.upper() if 0x20 <= ord(c) <= 0x7e][:6]
    return bytes(cleaned + [0x20] * (6 - len(cleaned)))


def nodes_payload(origin_alias, entries):
    """entries: list of (dest_call, dest_ssid, dest_alias, nh_call,
    nh_ssid, quality). Returns a list of payloads (one per <=11)."""
    payloads = []
    for start in range(0, len(entries), MAX_ENTRIES):
        chunk = entries[start:start + MAX_ENTRIES]
        body = bytearray([SIGNATURE]) + alias6(origin_alias)
        for dcall, dssid, dalias, ncall, nssid, quality in chunk:
            body += shifted_call(dcall, dssid)
            body += alias6(dalias)
            body += shifted_call(ncall, nssid)
            body.append(quality & 0xFF)
        payloads.append(bytes(body))
    return payloads


def decode_nodes(payload):
    """Round-trip decoder, for the validator. Returns (origin_alias,
    [(dest, dest_alias, neighbour, quality)]) or None."""
    if len(payload) < 7 or payload[0] != SIGNATURE:
        return None
    origin = payload[1:7].decode("ascii", "replace").strip()
    entries = []
    i = 7
    while i + 21 <= len(payload):
        d = _unshift(payload[i:i + 7])
        dalias = payload[i + 7:i + 13].decode("ascii", "replace").strip()
        n = _unshift(payload[i + 13:i + 20])
        q = payload[i + 20]
        entries.append((d, dalias, n, q))
        i += 21
    return origin, entries


def _unshift(field):
    call = "".join(chr(b >> 1) for b in field[:6]).strip()
    ssid = (field[6] >> 1) & 0x0F
    return f"{call}-{ssid}" if ssid else call
