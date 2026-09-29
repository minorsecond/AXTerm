#!/usr/bin/env python3
"""Capture a digipeater that repeats us and never answers.

The single most common station on a real APRS channel — and the one that made
"it hears me but won't answer" look like a bug in AXTerm. `modem-digi` is a
Direwolf with `DIGIPEAT` and no APRS application behind it, so it does exactly
what AD1CT does on the air.

    docker compose --profile rfnet up -d
    python3 digi_capture.py --out ../../AXTermTests/Fixtures/rf-digipeater.json
"""
import argparse, json, socket, sys, time
sys.path.insert(0, ".")
from xastir_oracle import ui_frame, deframe, decode
from ax25station import kiss_wrap

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1")
ap.add_argument("--port", type=int, default=8013)
ap.add_argument("--callsign", default="ORACLE-1")
ap.add_argument("--digi", default="RFDIGI-1")
ap.add_argument("--listen", type=float, default=14.0)
ap.add_argument("--out", default="rf-digipeater.json")
args = ap.parse_args()


def probe(kind, info, via):
    sock = socket.create_connection((args.host, args.port), timeout=5)
    sock.settimeout(0.5)
    sock.sendall(kiss_wrap(ui_frame(args.callsign, "APZAXT", info, via=via)))
    print(f"--> {kind}: {info} via {via}", flush=True)
    heard, buf, t0, seen = [], b"", time.time(), set()
    while time.time() - t0 < args.listen:
        try:
            buf += sock.recv(4096)
        except socket.timeout:
            continue
        frames, buf = deframe(buf)
        for raw in frames:
            got = decode(raw)
            if not got:
                continue
            dest, src, vias, payload = got
            key = (src, tuple(vias), payload)
            if key in seen:
                continue
            seen.add(key)
            rec = {
                "after_s": round(time.time() - t0, 2),
                "src": src, "dest": dest, "via": vias,
                "frame_hex": raw.hex(),
                "info_ascii": payload.decode("ascii", "replace"),
                "is_ours": src == args.callsign,
                "repeated_by_digi": args.digi in vias,
            }
            heard.append(rec)
            print(f"    <-- +{rec['after_s']:5.2f}s {src}>{dest} via={vias} "
                  f"{rec['info_ascii']!r}", flush=True)
    sock.close()
    return {"kind": kind, "sent_info": info, "sent_via": via, "heard": heard}


probes = [
    probe("beacon-via-wide", "=3936.70N/10443.90W-AXTerm oracle", ["WIDE1-1"]),
    probe("beacon-direct", "=3936.70N/10443.90W-AXTerm oracle direct", []),
    probe("query-position", ":%-9s:%s" % (args.digi, "?APRSP"), []),
    probe("query-version", ":%-9s:%s" % (args.digi, "?VER"), []),
    probe("query-trace", ":%-9s:%s" % (args.digi, "?APRST"), []),
    probe("query-via-wide", ":%-9s:%s" % (args.digi, "?APRSP"), ["WIDE1-1"]),
    # Xastir answering a query that arrived *through* the digipeater. It hears
    # both copies — the un-repeated one and the digipeated one — and answers
    # each, so the pair shows exactly how the has-been-repeated bit appears in
    # a PATH= answer.
    probe("trace-through-digi", ":%-9s:%s" % ("XASTIR-1", "?APRST"), ["WIDE1-1"]),
]

json.dump({
    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "digipeater": args.digi, "asked_as": args.callsign,
    "channel": "rfnet: 1200-baud AFSK, one Direwolf per station, shared audio bus",
    "note": "A Direwolf digipeater with no APRS application behind it — the "
            "AD1CT case. It repeats WIDEn-N traffic with callsign substitution "
            "and answers no query. Regenerate with TestRig/scripts/digi_capture.py.",
    "probes": probes,
}, open(args.out, "w"), indent=2)
print(f"\n-> {args.out}")
