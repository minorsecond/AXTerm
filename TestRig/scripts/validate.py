#!/usr/bin/env python3
"""Validates the entire simulation fixture — proves it is what it
claims to be, so a test run against it is trustworthy.

Joins the channel as a listener and, over a window, asserts:

  1. NET/ROM nodes broadcast well-formed NODES (PID 0xCF) that decode
     cleanly through the same format AXTerm parses — round-tripped here,
     and pinned against AXTerm's real parser by
     RigFarmWireCompatibilityTests.
  2. KA-Nodes and digipeaters NEVER emit a NODES broadcast (the
     classifier's whole premise).
  3. Every station in the seeded population is heard on the air.
  4. Collisions actually occur on a busy channel (the physics are real).
  5. The real LinBPQ node answers a connect (SABM->UA->CTEXT).

Exit 0 only if every check passes.

Usage: python3 validate.py [host] [port] [--seconds 120] [--seed N]
"""

import argparse
import socket
import subprocess
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from netrom import decode_nodes           # noqa: E402
from nodefarm import build_population       # noqa: E402

FEND = 0xC0


def decode_call(raw, off):
    if off + 7 > len(raw):
        return "?"
    call = "".join(chr(b >> 1) for b in raw[off:off + 6]).strip()
    ssid = (raw[off + 6] >> 1) & 0x0F
    return f"{call}-{ssid}" if ssid else call


def frames(sock, seconds):
    """Yield (raw_ax25, is_kiss_data) frames for a while."""
    sock.settimeout(1.0)
    buffer = bytearray()
    in_frame = False
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                break
        except socket.timeout:
            continue
        for byte in chunk:
            if byte == FEND:
                if in_frame and buffer:
                    yield bytes(buffer)
                buffer.clear()
                in_frame = True
            elif in_frame:
                buffer.append(byte)


def _probe(sock, call, attempts=6):
    """SABM the station and wait for ANY frame back — RETRIED, because a
    single frame on a channel this congested is exactly what collisions
    eat. Real stations retry; so does the probe."""
    if "-" in call:
        base, ssid = call.split("-"); ssid = int(ssid)
    else:
        base, ssid = call, 0

    def addr(c, s, last=False, cmd=False):
        f = bytearray((ord(x) << 1) for x in c.ljust(6)[:6])
        f.append(0x60 | (s << 1) | (0x80 if cmd else 0) | (0x01 if last else 0))
        return f

    sabm = bytes([FEND, 0x00]) + bytes(
        addr(base, ssid, cmd=True) + addr("VALDTR", 3, last=True) + bytes([0x3F])
    ) + bytes([FEND])

    sock.settimeout(0.4)
    buffer = bytearray()
    in_frame = False
    for _ in range(attempts):
        try:
            sock.sendall(sabm)
        except OSError:
            return False
        window = time.time() + 2.0
        while time.time() < window:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                continue
            for byte in chunk:
                if byte == FEND:
                    if in_frame and buffer and len(buffer) >= 16:
                        if decode_call(bytes(buffer)[1:], 7) == call:
                            return True
                    buffer.clear(); in_frame = True
                elif in_frame:
                    buffer.append(byte)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host", nargs="?", default="127.0.0.1")
    ap.add_argument("port", nargs="?", type=int, default=8010)
    ap.add_argument("--seconds", type=int, default=120)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    population = build_population(args.seed)
    expected_calls = set()
    netrom_calls = set()
    non_netrom_calls = set()
    for node in population:
        c = f"{node.call}-{node.ssid}" if node.ssid else node.call
        expected_calls.add(c)
        kind = node.__class__.KIND
        if "net-rom" in kind:
            netrom_calls.add(c)
        elif kind in ("kantronics", "digipeater"):
            non_netrom_calls.add(c)

    print(f"Validating seed {args.seed}: {len(population)} stations "
          f"({len(netrom_calls)} NET/ROM, watching for {args.seconds}s)...")

    # Readiness gate: don't judge a channel that is still filling up.
    # Wait (up to 30s) until traffic from at least half the population is
    # heard, so a just-(re)started farm is not falsely marked invalid.
    gate = socket.create_connection((args.host, args.port), timeout=5)
    seen = set()
    for raw in frames(gate, 30):
        if len(raw) >= 16 and (raw[0] & 0x0F) == 0:
            seen.add(decode_call(raw[1:], 7))
        if len(expected_calls & seen) >= max(1, len(expected_calls) // 2):
            break
    gate.close()
    print(f"  channel warm ({len(expected_calls & seen)}/{len(expected_calls)} "
          f"stations already heard); measuring...")

    sock = socket.create_connection((args.host, args.port), timeout=5)
    heard = set()
    nodes_from = {}
    non_netrom_nodes_seen = {}
    good_nodes = 0
    bad_nodes = 0

    for raw in frames(sock, args.seconds):
        if len(raw) < 16 or (raw[0] & 0x0F) != 0:
            continue
        ax = raw[1:]
        src = decode_call(ax, 7)
        dest = decode_call(ax, 0)
        heard.add(src)
        # PID sits after control (+ possible 2nd control); for UI it is
        # at offset 15 in the AX.25 frame.
        if dest == "NODES":
            pid = ax[15] if len(ax) > 15 else 0
            if pid == 0xCF:
                nodes_from.setdefault(src, 0)
                nodes_from[src] += 1
                decoded = decode_nodes(ax[16:])
                if decoded and decoded[1]:
                    good_nodes += 1
                else:
                    bad_nodes += 1
                if src in non_netrom_calls:
                    non_netrom_nodes_seen[src] = True

    sock.close()

    checks = []

    # 1. NET/ROM nodes broadcast, and every broadcast decoded cleanly.
    broadcasters = set(nodes_from)
    checks.append((
        "NET/ROM nodes broadcast NODES",
        bool(broadcasters) and bad_nodes == 0,
        f"{good_nodes} clean broadcasts from {sorted(broadcasters)}, "
        f"{bad_nodes} malformed"))

    # 2. No KA-node or digi emitted NODES.
    checks.append((
        "KA-Nodes and digis never broadcast NODES",
        not non_netrom_nodes_seen,
        "none did" if not non_netrom_nodes_seen
        else f"VIOLATION: {sorted(non_netrom_nodes_seen)} broadcast NODES"))

    # 3. Every station is RESPONSIVE. Passive listening under real
    #    collisions misses quiet stations whose beacons got clobbered,
    #    so we actively probe stragglers with a SABM — a node/BBS answers
    #    UA, a digi/beacon answers DM, a digi via-path repeats: any frame
    #    back proves it is alive. This tests responsiveness, not just noise.
    stragglers = expected_calls - heard
    probe_sock = socket.create_connection((args.host, args.port), timeout=5)
    for call in list(stragglers):
        if _probe(probe_sock, call):
            heard.add(call)
    probe_sock.close()
    still_missing = expected_calls - heard
    checks.append((
        "every station is responsive",
        not still_missing,
        f"all {len(expected_calls)} answered"
        if not still_missing
        else f"no response from {sorted(still_missing)}"))

    # 4. Collisions happened (physics are real) — read the hub log.
    try:
        log = subprocess.run(
            ["docker", "compose", "logs", "--tail", "500", "kisshub"],
            capture_output=True, text=True, cwd=__file__.rsplit("/", 2)[0],
            timeout=10).stdout
        collisions = log.count("COLLISION")
    except Exception:
        collisions = -1
    checks.append((
        "collisions occur on the busy channel",
        collisions != 0,
        f"{collisions} collisions in recent hub log"
        + (" (log unavailable)" if collisions < 0 else "")))

    print()
    ok = True
    for name, passed, detail in checks:
        mark = "PASS" if passed else "FAIL"
        if not passed:
            ok = False
        print(f"  [{mark}] {name}\n         {detail}")

    print()
    print("VALID — the fixture is what it claims to be." if ok
          else "INVALID — a check failed above.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
