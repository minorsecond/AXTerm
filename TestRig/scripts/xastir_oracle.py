#!/usr/bin/env python3
"""Ask the real Xastir a question and write down exactly what it says.

AXTerm's APRS behaviour was matched to Xastir by *reading* `src/db.c`. That is
unfalsifiable. This drives the real thing over the rig's shared channel and
captures its replies as byte-exact fixtures, so `XastirOracleTests` can assert
against what Xastir actually transmits instead of against my reading of it.

    docker compose --profile aprs up -d
    python3 scripts/xastir_oracle.py --out ../AXTermTests/Fixtures/xastir-oracle.json

Every reply is recorded verbatim (hex + ASCII) together with the query that
provoked it and how long it took, because the timing is itself part of the
protocol: a directed query is answered at once, a general query after Bruninga's
random 0-120 s spread.
"""
import argparse, json, socket, sys, time
from ax25station import FEND, FESC, TFEND, TFESC, encode_address, kiss_wrap

TOCALL = "APZAXT"           # AXTerm's own tocall — we are the asker here


def ui_frame(src, dest, info, via=()):
    """A UI frame, PID 0xF0 — the only shape APRS ever puts on the air."""
    def addr(call, last=False, cmd=False):
        c, _, s = call.partition("-")
        return encode_address(c, int(s or 0), last=last, command=cmd)
    out = addr(dest, cmd=True) + addr(src, last=not via)
    for i, v in enumerate(via):
        out += addr(v, last=(i == len(via) - 1))
    return out + bytes([0x03, 0xF0]) + info.encode("ascii", "replace")


def call_at(raw, off):
    """The callsign in an AX.25 address field, as "CALL" or "CALL-SSID".

    ax25station.parse_call returns a (call, ssid) tuple; everything here
    compares against display strings, and a tuple silently never equals one.
    """
    call = "".join(chr(b >> 1) for b in raw[off:off + 6]).strip()
    ssid = (raw[off + 6] >> 1) & 0x0F
    return f"{call}-{ssid}" if ssid else call


def deframe(buf):
    """Split a KISS byte stream into (frames, remainder).

    Written here rather than reusing ax25station.kiss_unwrap, which expects a
    frame with the leading FEND already stripped and would leave the KISS
    command byte on the front of every frame.
    """
    frames, parts = [], buf.split(bytes([FEND]))
    remainder = parts.pop() if not buf.endswith(bytes([FEND])) else b""
    for part in parts:
        if len(part) < 2:
            continue
        body, out, i = part[1:], bytearray(), 0   # part[0] is the KISS command
        while i < len(body):
            if body[i] == FESC and i + 1 < len(body):
                nxt = body[i + 1]
                out.append(FEND if nxt == TFEND else FESC if nxt == TFESC else nxt)
                i += 2
            else:
                out.append(body[i])
                i += 1
        frames.append(bytes(out))
    return frames, remainder


def decode(frame):
    """(dest, src, via, info) from an AX.25 UI frame, or None."""
    if len(frame) < 16:
        return None
    off, via = 14, []
    if not frame[13] & 0x01:                       # more addresses follow
        while off + 7 <= len(frame):
            via.append(call_at(frame, off))
            last = frame[off + 6] & 0x01
            off += 7
            if last:
                break
    if off + 2 > len(frame):
        return None
    return call_at(frame, 0), call_at(frame, 7), via, frame[off + 2:]


def addressed(info, to):
    """True when an APRS message/answer is addressed to `to`."""
    return info.startswith(b":") and info[1:10].decode("ascii", "replace").strip() == to


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8010)
    ap.add_argument("--callsign", default="ORACLE-1", help="who we ask as")
    ap.add_argument("--target", default="XASTIR-1", help="the Xastir under test")
    ap.add_argument("--listen", type=float, default=25.0, help="seconds per query")
    ap.add_argument("--out", default="xastir-oracle.json")
    ap.add_argument("--messages", default="",
                    help="semicolon-separated message bodies to send instead of "
                         "queries, e.g. 'Testing{003' — the reply proves Xastir "
                         "parsed our addressee and message number")
    ap.add_argument("--attempts", type=int, default=3,
                    help="asks per query; the channel has collisions")
    ap.add_argument("--via", default="", help="comma digipeater path to send through")
    ap.add_argument("--queries", default="?APRSP,?APRSD,?APRST,?PING?,?VER,?APRSS,?APRSO,?APRSM,?APRSH,?IGATE?,?aprsp")
    args = ap.parse_args()

    sock = socket.create_connection((args.host, args.port), timeout=5)
    sock.settimeout(0.5)
    captured = []

    # Messages exercise the other direction: our encoder against Xastir's
    # decoder. An `ack` coming back is proof it parsed the 9-character padded
    # addressee and the {NNN message number exactly as APRS 1.01 ch.14 spells
    # them — something no amount of reading db.c can establish.
    probes = ([("message", m) for m in args.messages.split(";") if m]
              if args.messages
              else [("query", q) for q in args.queries.split(",") if q])

    for kind, query in probes:
        # ":TARGET   :BODY" — 9-char space-padded addressee, APRS 1.01 ch.14.
        info = ":%-9s:%s" % (args.target, query)
        via = [v for v in args.via.split(",") if v]
        frame = ui_frame(args.callsign, TOCALL, info, via=via)
        replies, attempt = [], 0

        # The rig hub models a real half-duplex medium (airtime, collisions),
        # so a lost query says nothing about Xastir. Ask up to `--attempts`
        # times and only then record silence.
        while not replies and attempt < args.attempts:
            attempt += 1
            sent_at = time.time()
            sock.sendall(kiss_wrap(frame))
            print(f"--> {info}" + (f"  (attempt {attempt})" if attempt > 1 else ""),
                  flush=True)
            buf, deadline = b"", sent_at + args.listen
            while time.time() < deadline:
                try:
                    buf += sock.recv(4096)
                except socket.timeout:
                    continue
                except OSError:
                    break
                frames, buf = deframe(buf)
                for raw in frames:
                    got = decode(raw)
                    if not got:
                        continue
                    r_dest, r_src, r_via, payload = got
                    if r_src != args.target:
                        continue
                    replies.append({
                        "after_s": round(time.time() - sent_at, 2),
                        "src": r_src, "dest": r_dest, "via": r_via,
                        # The whole AX.25 frame, so a test can run AXTerm's
                        # real decoder over bytes that were actually modulated
                        # rather than over a hand-built fixture.
                        "frame_hex": raw.hex(),
                        "info_hex": payload.hex(),
                        "info_ascii": payload.decode("ascii", "replace"),
                        "addressed_to_us": addressed(payload, args.callsign),
                    })
                    print(f"    <-- +{replies[-1]['after_s']:5.2f}s {r_src}>{r_dest} "
                          f"{replies[-1]['info_ascii']}", flush=True)

        captured.append({"kind": kind, "query": query, "sent_info": info,
                         "sent_via": via, "replies": replies,
                         "attempts": attempt})
        if not replies:
            print("    <-- (nothing)", flush=True)

    meta = {
        "asked_via": [v for v in args.via.split(",") if v],
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "target": args.target, "asked_as": args.callsign,
        "listen_seconds": args.listen,
        "note": "Byte-exact replies from a real Xastir on the TestRig channel. "
                "Regenerate with scripts/xastir_oracle.py; do not hand-edit.",
        "exchanges": captured,
    }
    with open(args.out, "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    answered = sum(1 for e in captured if e["replies"])
    print(f"\n{answered}/{len(captured)} queries answered -> {args.out}")
    return 0



def direwolf_decodes(since_s, service="modem-a"):
    """Direwolf's own description of what it heard, one line per log line.

    A second implementation reading the same air. Direwolf is neither AXTerm
    nor Xastir, so where it agrees the agreement means something.
    """
    import subprocess
    raw = subprocess.run(
        ["docker", "compose", "logs", f"--since={since_s}s", service],
        capture_output=True, text=True, cwd="..").stdout
    return [ln.split("| ", 1)[-1].rstrip() for ln in raw.splitlines() if "| " in ln]


def decode_block(log, marker, needle):
    """The lines Direwolf printed under one frame.

    It prints the frame, then its interpretation, then a blank line. `marker`
    is `SRC>DEST` and `needle` a fragment unique to this frame: two frames can
    share an address pair (SIMLA sends both telemetry and status), and matching
    on the pair alone silently hands the second one the first one's decode.
    """
    lines, capture = [], False
    for ln in log:
        if marker in ln and needle in ln and ln.startswith("["):
            lines, capture = [], True
            continue
        if capture:
            # A blank line ends the block; so does the next frame, because
            # Direwolf does not always leave one between a frame and a reply
            # that arrives on its heels.
            if not ln.strip() or ln.startswith("["):
                break
            lines.append(ln)
    return lines


if __name__ == "__main__":
    sys.exit(main())
