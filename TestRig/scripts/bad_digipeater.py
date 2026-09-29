#!/usr/bin/env python3
"""A digipeater that misbehaves in every documented way, so AXTerm can
be tested against the real hazards of RF relaying — not the clean
textbook case.

It joins the channel as RELAY (SSID configurable), and for every frame
whose via path names it with the H bit clear, it does the correct
thing (set H, retransmit) PLUS, per the chosen profile, one or more
pathologies real digipeaters actually exhibit:

  --dupe P      retransmit a fraction P of repeats twice (stuck PTT)
  --delay MS    hold repeats this long (a slow store-and-forward digi)
  --corrupt P   flip a random bit in a fraction P of repeats (marginal
                copy) — the frame still repeats, but altered
  --drop P      silently fail to repeat a fraction P (deaf on TX)
  --reorder     buffer two repeats and emit them swapped (a digi that
                batches)
  --no-hbit     retransmit WITHOUT setting the H bit — the classic
                digipeater loop that floods a channel

Usage:
  python3 bad_digipeater.py [host] [port] --alias RELAY --dupe 0.3 --delay 200

Point AXTerm at a destination `VIA RELAY` and watch how it copes with
the duplicates, delays, and corruption its retries then have to survive.
"""

import argparse
import random
import socket
import threading
import time

FEND, FESC, TFEND, TFESC = 0xC0, 0xDB, 0xDC, 0xDD


def unescape(data):
    out = bytearray()
    i = 0
    while i < len(data):
        b = data[i]
        if b == FESC and i + 1 < len(data):
            nxt = data[i + 1]
            out.append(FEND if nxt == TFEND else FESC if nxt == TFESC else nxt)
            i += 2
        else:
            out.append(b)
            i += 1
    return bytes(out)


def kiss_wrap(payload):
    out = bytearray([FEND, 0x00])
    for b in payload:
        if b == FEND:
            out += bytes([FESC, TFEND])
        elif b == FESC:
            out += bytes([FESC, TFESC])
        else:
            out.append(b)
    out.append(FEND)
    return bytes(out)


def decode_call(raw, off):
    if off + 7 > len(raw):
        return "?"
    call = "".join(chr(b >> 1) for b in raw[off:off + 6]).strip()
    ssid = (raw[off + 6] >> 1) & 0x0F
    return f"{call}-{ssid}" if ssid else call


class BadDigi:
    def __init__(self, args):
        self.args = args
        self.me = f"{args.alias}-{args.ssid}" if args.ssid else args.alias
        self.reorder_buffer = []
        self.lock = threading.Lock()

    def my_hop_offset(self, raw):
        """Offset of our address in the digi path if it is our turn, else None."""
        if len(raw) < 16 or (raw[13] & 0x01):  # no digis
            return None
        off = 14
        while off + 7 <= len(raw):
            repeated = raw[off + 6] & 0x80
            if not repeated:
                return off if decode_call(raw, off) == self.me else None
            if raw[off + 6] & 0x01:
                return None
            off += 7
        return None

    def transmit(self, sock, frame, why):
        sock.sendall(kiss_wrap(frame))
        src = decode_call(frame, 7)
        print(f"  -> repeated {src}'s frame [{why}]", flush=True)

    def handle_repeat(self, sock, raw, off):
        a = self.args
        if a.drop and random.random() < a.drop:
            print("  x dropped (deaf on TX)", flush=True)
            return

        frame = bytearray(raw)
        if not a.no_hbit:
            frame[off + 6] |= 0x80  # the correct thing
        why = "H set" if not a.no_hbit else "NO H BIT (loop!)"

        if a.corrupt and random.random() < a.corrupt:
            # Flip a bit in the info part, past the header.
            if len(frame) > 20:
                pos = random.randint(16, len(frame) - 1)
                frame[pos] ^= 1 << random.randint(0, 7)
                why += " +corrupted"

        emit = bytes(frame)

        def do_emit():
            if a.reorder:
                with self.lock:
                    self.reorder_buffer.append((emit, why))
                    if len(self.reorder_buffer) >= 2:
                        b = self.reorder_buffer
                        self.transmit(sock, b[1][0], b[1][1] + " (reordered)")
                        self.transmit(sock, b[0][0], b[0][1] + " (reordered)")
                        self.reorder_buffer = []
                return
            self.transmit(sock, emit, why)
            if a.dupe and random.random() < a.dupe:
                time.sleep(0.05)
                self.transmit(sock, emit, why + " (DUPLICATE)")

        if a.delay:
            threading.Timer(a.delay / 1000.0, do_emit).start()
        else:
            do_emit()

    def run(self):
        a = self.args
        sock = socket.create_connection((a.host, a.port), timeout=5)
        active = [name for name in
                  ("dupe", "delay", "corrupt", "drop", "reorder", "no_hbit")
                  if getattr(a, name)]
        print(f"{self.me} on frequency, misbehaving: "
              f"{', '.join(active) or 'nothing (well-behaved!)'}", flush=True)

        buffer = bytearray()
        in_frame = False
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            for byte in chunk:
                if byte == FEND:
                    if in_frame and buffer:
                        raw = unescape(bytes(buffer[1:]))  # drop KISS cmd byte
                        off = self.my_hop_offset(raw)
                        if off is not None:
                            self.handle_repeat(sock, raw, off)
                    buffer.clear()
                    in_frame = True
                elif in_frame:
                    buffer.append(byte)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host", nargs="?", default="127.0.0.1")
    ap.add_argument("port", nargs="?", type=int, default=8010)
    ap.add_argument("--alias", default="RELAY")
    ap.add_argument("--ssid", type=int, default=0)
    ap.add_argument("--dupe", type=float, default=0.0)
    ap.add_argument("--delay", type=float, default=0.0, help="ms")
    ap.add_argument("--corrupt", type=float, default=0.0)
    ap.add_argument("--drop", type=float, default=0.0)
    ap.add_argument("--reorder", action="store_true")
    ap.add_argument("--no-hbit", action="store_true")
    args = ap.parse_args()
    try:
        BadDigi(args).run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
