#!/usr/bin/env python3
"""The shared channel, at the KISS layer.

Every station on a simplex frequency hears every other station. This
hub gives the docker rig that property: each TCP client speaks KISS,
and every complete frame a client sends is forwarded to every OTHER
client. Frames are forwarded whole (parsed on FEND boundaries), so two
stations' bytes never interleave mid-frame — a perfect channel by
default, degradable on purpose:

    LOSS=0.15       drop this fraction of frames at random
    DELAY_MS=120    mean one-way latency
    JITTER_MS=80    +/- uniform jitter on that latency

AXTerm connects from the host (127.0.0.1:8010) exactly as it would to
a TNC; LinBPQ connects from its container. Neither can tell the
difference between this and a quiet channel — which is the point. For
modulated-audio realism, use the `rf` profile instead (see README).
"""

import asyncio
import os
import random
import sys
import time

FEND = 0xC0
LOSS = float(os.environ.get("LOSS", "0"))
DELAY_MS = float(os.environ.get("DELAY_MS", "0"))
JITTER_MS = float(os.environ.get("JITTER_MS", "0"))
PORT = int(os.environ.get("PORT", "8010"))

clients = {}  # writer -> label
counter = 0


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def decode_call(frame, offset):
    """Callsign out of a shifted AX.25 address field, for the log."""
    if offset + 7 > len(frame):
        return "?"
    call = "".join(chr(b >> 1) for b in frame[offset:offset + 6]).strip()
    ssid = (frame[offset + 6] >> 1) & 0x0F
    return f"{call}-{ssid}" if ssid else call


def describe(frame):
    """`src>dst (n bytes)` for a KISS data frame, best-effort."""
    if len(frame) < 16 or (frame[0] & 0x0F) != 0:
        return f"cmd 0x{frame[0]:02x} ({len(frame)}B)" if frame else "empty"
    return f"{decode_call(frame, 8)}>{decode_call(frame, 1)} ({len(frame)}B)"


async def forward(frame, sender):
    if LOSS > 0 and random.random() < LOSS:
        log(f"  ~ dropped on the channel: {describe(frame)}")
        return
    if DELAY_MS > 0 or JITTER_MS > 0:
        delay = max(0.0, DELAY_MS + random.uniform(-JITTER_MS, JITTER_MS))
        await asyncio.sleep(delay / 1000.0)
    wrapped = bytes([FEND]) + frame + bytes([FEND])
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
    log(f"+ {label} joined the channel from {peer} "
        f"({len(clients)} on frequency)")

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
                        log(f"  {label}: {describe(frame)}")
                        await forward(frame, writer)
                    buffer.clear()
                    in_frame = True
                elif in_frame:
                    buffer.append(byte)
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        clients.pop(writer, None)
        log(f"- {label} left the channel ({len(clients)} on frequency)")
        try:
            writer.close()
        except Exception:
            pass


async def main():
    server = await asyncio.start_server(handle, "0.0.0.0", PORT)
    conditions = []
    if LOSS:
        conditions.append(f"loss={LOSS:.0%}")
    if DELAY_MS:
        conditions.append(f"delay={DELAY_MS:.0f}±{JITTER_MS:.0f}ms")
    log(f"KISS hub listening on :{PORT} "
        + (f"({', '.join(conditions)})" if conditions else "(perfect channel)"))
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
