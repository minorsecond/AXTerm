#!/usr/bin/env python3
"""Proves the dual rig without AXTerm: listens on hub A (:8010) and hub B
(:8020) and waits for the NODES broadcasts that say who is where.

Expected: TSTNOD (BPQTST-7) on A only, CHBNOD (BPQTX3-7) on B only, and
BRGNOD (BPQTX4-7) on both. If this passes, anything AXTerm then shows
differently is AXTerm's.

Usage: python3 smoke_dual.py [host] [portA] [portB]   (default 127.0.0.1 8010 8020)
"""

import socket
import sys
import time

FEND = 0xC0
FESC, TFEND, TFESC = 0xDB, 0xDC, 0xDD
EXPECTED = {"BPQTST-7": {"A"}, "BPQTX3-7": {"B"}, "BPQTX4-7": {"A", "B"}}


def decode_address(field):
    call = "".join(chr(b >> 1) for b in field[:6]).strip()
    ssid = (field[6] >> 1) & 0x0F
    return f"{call}-{ssid}" if ssid else call


def frames(buffer):
    """Split a KISS byte stream into unescaped AX.25 frames."""
    out, frame, in_frame, escape = [], bytearray(), False, False
    for byte in buffer:
        if byte == FEND:
            if in_frame and len(frame) > 1:
                out.append(bytes(frame[1:]))  # drop the KISS command byte
            frame, in_frame, escape = bytearray(), True, False
        elif in_frame:
            if escape:
                frame.append(FEND if byte == TFEND else FESC if byte == TFESC else byte)
                escape = False
            elif byte == FESC:
                escape = True
            else:
                frame.append(byte)
    return out


def nodes_origins(sock, seconds):
    """Callsigns whose NODES broadcast (PID 0xCF to NODES) arrived within `seconds`."""
    sock.settimeout(1.0)
    deadline, seen, buffer = time.time() + seconds, set(), bytearray()
    while time.time() < deadline:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            break
        buffer += chunk
        for frame in frames(buffer):
            if len(frame) < 17:
                continue
            dest, src = decode_address(frame[0:7]), decode_address(frame[7:14])
            if dest == "NODES" and frame[15] == 0xCF:
                seen.add(src)
        # keep only an unterminated tail
        last = buffer.rfind(bytes([FEND]))
        buffer = buffer[last:] if last >= 0 else buffer
    return seen


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    ports = {"A": int(sys.argv[2]) if len(sys.argv) > 2 else 8010,
             "B": int(sys.argv[3]) if len(sys.argv) > 3 else 8020}
    # Both hubs at once, for two NODES intervals: on a half-duplex channel
    # with several nodes a single broadcast can be lost to a collision, and
    # the rig models exactly that.
    import threading
    heard, threads = {}, []
    for hub, port in ports.items():
        def listen(hub=hub, port=port):
            with socket.create_connection((host, port), timeout=5) as sock:
                heard[hub] = nodes_origins(sock, 150)
        threads.append(threading.Thread(target=listen))
    print(f"listening 150 s on {', '.join(f'hub {h} ({host}:{p})' for h, p in ports.items())} for NODES…")
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for hub in ports:
        print(f"hub {hub}: {sorted(heard.get(hub, set())) or 'nothing'}")

    ok = True
    for node, hubs in EXPECTED.items():
        on = {hub for hub in ports if node in heard[hub]}
        mark = "ok " if on == hubs else "BAD"
        if on != hubs:
            ok = False
        print(f"{mark} {node}: expected on {sorted(hubs)}, heard on {sorted(on)}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
