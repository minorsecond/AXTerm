#!/usr/bin/env python3
"""Adversarial noise on the channel: joins the frequency and sprays
malformed, truncated, oversized, and outright hostile frames at whoever
is listening — AXTerm, LinBPQ, both. Nothing here is a valid
conversation; the point is that a station on a shared frequency hears
everything, including garbage from a half-broken TNC three counties
over, and must not crash, hang, or corrupt its state because of it.

Run it while AXTerm is connected to the rig. Watch AXTerm's console
and Sentry; watch `docker compose logs -f linbpq`. A healthy station
shrugs all of this off.

    python3 fuzz_channel.py [host] [port] [--seconds N] [--seed S]

Seeded, so a run that provokes a fault reproduces from its seed.
"""

import argparse
import random
import socket
import sys
import time

FEND, FESC, TFEND, TFESC = 0xC0, 0xDB, 0xDC, 0xDD


def kiss_wrap(payload, port_cmd=0x00):
    out = bytearray([FEND, port_cmd])
    for b in payload:
        if b == FEND:
            out += bytes([FESC, TFEND])
        elif b == FESC:
            out += bytes([FESC, TFESC])
        else:
            out.append(b)
    out.append(FEND)
    return bytes(out)


def addr(call, ssid, rng, last=False):
    field = bytearray((ord(c) << 1) for c in call.ljust(6)[:6])
    field.append(0x60 | (ssid << 1) | (0x01 if last else 0))
    return field


def a_plausible_header(rng):
    calls = ["W0ARP", "K0EPI", "KD0SSP", "N0BODY", "BPQTST", "CQ", "ID", "NODES"]
    dest = addr(rng.choice(calls), rng.randint(0, 15), rng)
    src = addr(rng.choice(calls), rng.randint(0, 15), rng, last=True)
    return dest + src


GENERATORS = []


def generator(fn):
    GENERATORS.append(fn)
    return fn


@generator
def pure_noise(rng):
    """Random bytes, any length — the modem handed us static."""
    return bytes(rng.randint(0, 255) for _ in range(rng.randint(0, 330)))


@generator
def truncated_frame(rng):
    """A valid header cut off mid-address — a collision clipped it."""
    header = a_plausible_header(rng)
    cut = rng.randint(0, len(header))
    return bytes(header[:cut])


@generator
def header_only(rng):
    """Addresses but no control byte — nothing to classify."""
    return bytes(a_plausible_header(rng))


@generator
def oversized_iframe(rng):
    """An I-frame far past any sane paclen — a runaway TNC."""
    body = a_plausible_header(rng) + bytes([0x00, 0xF0])
    body += bytes(rng.randint(0, 255) for _ in range(rng.randint(300, 900)))
    return bytes(body)


@generator
def wrong_pid(rng):
    """0xCF (NET/ROM) PID on a frame that is not a NODES broadcast, or
    a NODES destination with a random L3 body — the classifier's edge."""
    header = a_plausible_header(rng)
    return bytes(header + bytes([0x00, 0xCF]) + bytes(rng.randint(0, 255)
                 for _ in range(rng.randint(0, 60))))


@generator
def bad_control(rng):
    """Every possible control byte against one header — walks the I/S/U
    space including reserved encodings."""
    header = a_plausible_header(rng)
    return bytes(header + bytes([rng.randint(0, 255), rng.randint(0, 255)]))


@generator
def digi_path_storm(rng):
    """A frame with a long, contradictory digipeater path: some hops
    marked repeated, some not, out of order — the H-bit logic's nightmare."""
    dest = addr(rng.choice(["CQ", "K0EPI"]), 0, rng)
    src = addr("W0ARP", 1, rng)
    frame = bytearray(dest + src)
    hops = rng.randint(1, 8)
    for i in range(hops):
        field = addr(rng.choice(["K0EPI", "DWARC", "RELAY", "WIDE"]),
                     rng.randint(0, 15), rng, last=(i == hops - 1))
        if rng.random() < 0.5:
            field[6] |= 0x80  # H bit, randomly
        frame += field
    frame += bytes([0x03, 0xF0]) + b"via storm"
    return bytes(frame)


@generator
def kiss_escape_abuse(rng):
    """Malformed KISS escaping: FESC followed by junk, stray TFEND —
    tests the un-escaper directly, below the AX.25 layer."""
    body = bytearray()
    for _ in range(rng.randint(2, 40)):
        r = rng.random()
        if r < 0.4:
            body += bytes([FESC, rng.randint(0, 255)])  # bad escape
        elif r < 0.6:
            body.append(TFEND)
        else:
            body.append(rng.randint(0, 255))
    return bytes(body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host", nargs="?", default="127.0.0.1")
    ap.add_argument("port", nargs="?", type=int, default=8010)
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--rate", type=float, default=20.0, help="frames/sec")
    args = ap.parse_args()

    seed = args.seed if args.seed is not None else random.randrange(1 << 30)
    rng = random.Random(seed)
    print(f"Fuzzing {args.host}:{args.port} for {args.seconds}s "
          f"at {args.rate}/s (seed {seed}).")
    print("Watch AXTerm's console and Sentry. A healthy station ignores all of it.")

    sock = socket.create_connection((args.host, args.port), timeout=5)
    counts = {}
    deadline = time.time() + args.seconds
    interval = 1.0 / args.rate
    sent = 0
    try:
        while time.time() < deadline:
            gen = rng.choice(GENERATORS)
            payload = gen(rng)
            # Half the time send it as a well-formed KISS data frame;
            # half the time abuse the KISS framing itself.
            if gen is kiss_escape_abuse or rng.random() < 0.2:
                raw = bytes([FEND, 0x00]) + payload + bytes([FEND])
            else:
                raw = kiss_wrap(payload)
            try:
                sock.sendall(raw)
            except (ConnectionError, BrokenPipeError):
                print("Channel closed under us — the hub or a peer went away.")
                break
            counts[gen.__name__] = counts.get(gen.__name__, 0) + 1
            sent += 1
            time.sleep(interval)
    except KeyboardInterrupt:
        pass
    finally:
        sock.close()

    print(f"\nSent {sent} hostile frames (seed {seed}):")
    for name, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {n:5d}  {name}")
    print("\nIf AXTerm is still responsive and connected, it passed. "
          "If it crashed, rerun with --seed", seed, "to reproduce.")


if __name__ == "__main__":
    sys.exit(main())
