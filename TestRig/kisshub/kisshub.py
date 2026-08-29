#!/usr/bin/env python3
"""The shared channel — now with the physics that were missing.

A simplex packet frequency is a half-duplex medium: a frame takes real
airtime to send (1200 baud is slow — a 100-byte frame is two-thirds of
a second), and while one station transmits, another that also keys up
DESTROYS both — the collision every CSMA scheme exists to avoid. Bytes
also arrive imperfect: a marginal path flips bits inside an otherwise
whole frame.

This hub models all of it:

  BAUD=1200          airtime = bytes*8/baud + txdelay; the medium is
                     busy for that long, and everyone waits
  COLLISIONS=1       overlapping transmissions collide — BOTH lost
                     (the honest result; capture effect is off by
                     default). This is what forces real retries and
                     tests backoff, and it is the hidden-node problem
                     by construction: TCP-KISS carries no carrier sense
                     back to the stations, so they cannot hear each
                     other and must recover from the wreck.
  BER=0.0            per-bit error rate INSIDE a delivered frame — a
                     marginal copy that still arrives (CRC would catch
                     it on real hardware; here it reaches the decoder)
  LOSS=0.0           whole-frame drop, independent of collisions
  DELAY_MS/JITTER_MS extra propagation latency on top of airtime
  CAPTURE=0          if 1, the frame that started first survives a
                     collision (a strong near station capturing a weak
                     far one)

Set COLLISIONS=0 BAUD=0 for the old instant, perfect channel.
"""

import asyncio
import os
import random
import sys
import time

FEND = 0xC0
BAUD = float(os.environ.get("BAUD", "1200"))
TXDELAY_MS = float(os.environ.get("TXDELAY_MS", "30"))
COLLISIONS = os.environ.get("COLLISIONS", "1") != "0"
CAPTURE = os.environ.get("CAPTURE", "0") != "0"
BER = float(os.environ.get("BER", "0"))
LOSS = float(os.environ.get("LOSS", "0"))
DELAY_MS = float(os.environ.get("DELAY_MS", "0"))
JITTER_MS = float(os.environ.get("JITTER_MS", "0"))
PORT = int(os.environ.get("PORT", "8010"))

clients = {}
counter = 0
inflight = []  # live transmissions, for collision detection
stats = {"sent": 0, "delivered": 0, "collided": 0, "lost": 0, "corrupted": 0}


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def decode_call(frame, offset):
    if offset + 7 > len(frame):
        return "?"
    call = "".join(chr(b >> 1) for b in frame[offset:offset + 6]).strip()
    ssid = (frame[offset + 6] >> 1) & 0x0F
    return f"{call}-{ssid}" if ssid else call


def describe(frame):
    if len(frame) < 16 or (frame[0] & 0x0F) != 0:
        return f"cmd 0x{frame[0]:02x} ({len(frame)}B)" if frame else "empty"
    return f"{decode_call(frame, 8)}>{decode_call(frame, 1)} ({len(frame)}B)"


def airtime(frame):
    if BAUD <= 0:
        return 0.0
    return (len(frame) * 8.0) / BAUD + TXDELAY_MS / 1000.0


def apply_ber(frame):
    if BER <= 0:
        return frame, 0
    out = bytearray(frame)
    flips = 0
    for i in range(len(out)):
        for bit in range(8):
            if random.random() < BER:
                out[i] ^= (1 << bit)
                flips += 1
    return bytes(out), flips


class Tx:
    __slots__ = ("frame", "sender", "start", "end", "collided")

    def __init__(self, frame, sender, start, end):
        self.frame = frame
        self.sender = sender
        self.start = start
        self.end = end
        self.collided = False


async def transmit(frame, sender):
    """One station keys up. Occupy the medium; collide with anyone
    already transmitting; deliver (or not) when the airtime elapses."""
    stats["sent"] += 1
    now = time.monotonic()
    air = airtime(frame)
    tx = Tx(frame, sender, now, now + air)

    if COLLISIONS:
        for other in inflight:
            if other.sender is sender:
                continue
            # Overlap in time on a shared medium is a collision.
            if tx.start < other.end and other.start < tx.end:
                if CAPTURE and other.start < tx.start:
                    tx.collided = True            # the earlier one wins
                elif CAPTURE and tx.start < other.start:
                    other.collided = True
                else:
                    tx.collided = True
                    other.collided = True
                log(f"  ## COLLISION: {describe(frame)} vs "
                    f"{describe(other.frame)}")

    inflight.append(tx)
    try:
        if air > 0:
            await asyncio.sleep(air)
    finally:
        if tx in inflight:
            inflight.remove(tx)

    if tx.collided:
        stats["collided"] += 1
        return  # wreckage — nobody decodes it
    if LOSS > 0 and random.random() < LOSS:
        stats["lost"] += 1
        log(f"  ~ faded out: {describe(frame)}")
        return
    if DELAY_MS > 0 or JITTER_MS > 0:
        await asyncio.sleep(max(0.0, DELAY_MS + random.uniform(-JITTER_MS, JITTER_MS)) / 1000.0)

    out, flips = apply_ber(frame)
    if flips:
        stats["corrupted"] += 1
        log(f"  * {flips} bit error(s) in {describe(frame)}")

    stats["delivered"] += 1
    wrapped = bytes([FEND]) + out + bytes([FEND])
    for writer, label in list(clients.items()):
        if writer is sender:
            continue
        try:
            writer.write(wrapped)
            await writer.drain()
        except (ConnectionError, RuntimeError):
            pass


async def handle(reader, writer):
    global counter
    counter += 1
    label = f"station{counter}"
    peer = writer.get_extra_info("peername")
    clients[writer] = label
    log(f"+ {label} joined from {peer} ({len(clients)} on frequency)")

    buffer = bytearray()
    in_frame = False
    try:
        while True:
            chunk = await reader.read(4096)
            if not chunk:
                break
            for byte in chunk:
                if byte == FEND:
                    if in_frame and buffer:
                        frame = bytes(buffer)
                        log(f"  {label} keys up: {describe(frame)}")
                        # Fire-and-forget: the sender is not blocked by
                        # its own airtime here (its TNC would be), but
                        # the medium is, which is what collisions need.
                        asyncio.ensure_future(transmit(frame, writer))
                    buffer.clear()
                    in_frame = True
                elif in_frame:
                    buffer.append(byte)
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        clients.pop(writer, None)
        log(f"- {label} left ({len(clients)} on frequency)")
        try:
            writer.close()
        except Exception:
            pass


async def report():
    while True:
        await asyncio.sleep(30)
        s = stats
        if s["sent"]:
            log(f"  channel: {s['delivered']} delivered, {s['collided']} "
                f"collided, {s['lost']} faded, {s['corrupted']} bit-hit "
                f"(of {s['sent']} keyed)")


async def main():
    server = await asyncio.start_server(handle, "0.0.0.0", PORT)
    knobs = [f"baud={BAUD:.0f}"]
    if COLLISIONS:
        knobs.append("collisions" + (" (capture)" if CAPTURE else ""))
    if BER:
        knobs.append(f"ber={BER}")
    if LOSS:
        knobs.append(f"loss={LOSS:.0%}")
    if DELAY_MS:
        knobs.append(f"delay={DELAY_MS:.0f}±{JITTER_MS:.0f}ms")
    log(f"Shared channel on :{PORT} — {', '.join(knobs)}")
    asyncio.ensure_future(report())
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
