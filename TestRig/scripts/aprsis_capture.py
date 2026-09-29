#!/usr/bin/env python3
"""Capture the APRS-IS feed for a window, to compare against what our radio heard.

aprs.fi is a view onto APRS-IS, not a separate source: what it shows for a
station is what an igate put onto this stream. Reading the stream directly is
what makes a *window* comparable — the aprs.fi API answers "where is this
station now", which cannot tell you what was missed half an hour ago.

Read-only: the login uses passcode -1, which APRS-IS accepts for receive and
refuses for transmit. Nothing this script does can put a byte on the air or on
the network's message stream.
"""
import argparse, json, socket, time, sys

ap = argparse.ArgumentParser()
ap.add_argument("--call", required=True)
ap.add_argument("--lat", type=float, required=True)
ap.add_argument("--lon", type=float, required=True)
ap.add_argument("--radius-km", type=float, default=150)
ap.add_argument("--seconds", type=float, default=1800)
ap.add_argument("--host", default="rotate.aprs2.net")
ap.add_argument("--port", type=int, default=14580)
ap.add_argument("--out", required=True)
args = ap.parse_args()

filt = f"r/{args.lat}/{args.lon}/{args.radius_km}"
sock = socket.create_connection((args.host, args.port), timeout=20)
sock.settimeout(5)
login = f"user {args.call} pass -1 vers AXTerm-compare 1.0 filter {filt}\r\n"
sock.sendall(login.encode())

started = time.time()
buf, n, servers = b"", 0, []
with open(args.out, "w") as fh:
    fh.write(json.dumps({"kind": "meta", "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                         "started_epoch": started, "filter": filt, "host": args.host,
                         "seconds": args.seconds}) + "\n")
    while time.time() - started < args.seconds:
        try:
            chunk = sock.recv(8192)
        except socket.timeout:
            continue
        except OSError as e:
            fh.write(json.dumps({"kind": "error", "at": time.time() - started, "why": str(e)}) + "\n")
            break
        if not chunk:
            fh.write(json.dumps({"kind": "error", "at": time.time() - started, "why": "server closed"}) + "\n")
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            raw = line.rstrip(b"\r")
            text = raw.decode("latin-1")
            if not text:
                continue
            now = time.time()
            if text.startswith("#"):
                servers.append(text)
                fh.write(json.dumps({"kind": "server", "at": round(now - started, 2), "text": text}) + "\n")
            else:
                n += 1
                fh.write(json.dumps({"kind": "frame", "at": round(now - started, 2),
                                     "epoch": now, "text": text,
                                     "hex": raw.hex()}) + "\n")
            fh.flush()
    fh.write(json.dumps({"kind": "meta", "ended_epoch": time.time(), "frames": n}) + "\n")
sock.close()
print(f"{n} frames in {time.time() - started:.0f}s -> {args.out}")
