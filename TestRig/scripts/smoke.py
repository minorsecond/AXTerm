#!/usr/bin/env python3
"""Proves the rig without AXTerm: joins the channel as SMOKE-1, waits
for BPQTST-7's NODES broadcast, then connects to it over AX.25 and
prints the CTEXT the node answers with. If this passes, the channel
and the node are real — anything AXTerm then fails at is AXTerm's.

Usage: python3 smoke.py [host] [port]     (default 127.0.0.1 8010)
"""

import socket
import sys
import time

FEND = 0xC0
FESC, TFEND, TFESC = 0xDB, 0xDC, 0xDD
MYCALL, NODE = ("SMOKE", 1), ("BPQTST", 7)


def address(call, ssid, last=False, c_bit=False):
    field = bytearray((ord(ch) << 1) for ch in call.ljust(6))
    byte = 0x60 | (ssid << 1) | (0x80 if c_bit else 0)
    if last:
        byte |= 0x01
    field.append(byte)
    return bytes(field)


def kiss_wrap(ax25):
    escaped = bytearray()
    for byte in ax25:
        if byte == FEND:
            escaped += bytes([FESC, TFEND])
        elif byte == FESC:
            escaped += bytes([FESC, TFESC])
        else:
            escaped.append(byte)
    return bytes([FEND, 0x00]) + bytes(escaped) + bytes([FEND])


def frame(dest, src, control, pid=None, payload=b""):
    raw = address(*dest, c_bit=True) + address(*src, last=True) + bytes([control])
    if pid is not None:
        raw += bytes([pid]) + payload
    return raw


def decode_call(raw, offset):
    call = "".join(chr(b >> 1) for b in raw[offset:offset + 6]).strip()
    ssid = (raw[offset + 6] >> 1) & 0x0F
    return f"{call}-{ssid}" if ssid else call


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8010
    sock = socket.create_connection((host, port), timeout=5)
    sock.settimeout(1.0)
    print(f"On frequency via {host}:{port} as SMOKE-1.")

    buffer = bytearray()
    in_frame = False
    connected = False
    saw_nodes = False
    ctext = bytearray()
    sabm_sent_at = None
    deadline = time.time() + 150

    def frames_from(chunk):
        nonlocal in_frame
        out = []
        for byte in chunk:
            if byte == FEND:
                if in_frame and buffer:
                    out.append(bytes(buffer))
                buffer.clear()
                in_frame = True
            elif in_frame:
                buffer.append(byte)
        return out

    def send(ax25):
        sock.sendall(kiss_wrap(ax25))

    while time.time() < deadline:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            chunk = b""
        if chunk == b"" and sabm_sent_at and time.time() - sabm_sent_at > 20:
            print("FAIL: no answer to SABM in 20s")
            return 1

        for raw in frames_from(chunk):
            if len(raw) < 16 or (raw[0] & 0x0F) != 0:
                continue
            ax = raw[1:]
            dest, src = decode_call(ax, 0), decode_call(ax, 7)
            control = ax[14]
            if dest == "NODES" and not saw_nodes:
                saw_nodes = True
                print(f"PASS: heard a NODES broadcast from {src} "
                      f"(PID 0x{ax[15]:02x}) — the node is alive and talking.")
                print("Connecting to it...")
                send(frame(NODE, MYCALL, 0x3F))  # SABM P
                sabm_sent_at = time.time()
            elif src == "BPQTST-7" and (control & 0xEF) == 0x63 and not connected:
                connected = True
                print("PASS: BPQTST-7 answered our SABM with UA — link up.")
            elif src == "BPQTST-7" and connected and (control & 0x01) == 0:
                ctext += ax[16:]
                nr = ((control >> 1) & 0x07) + 1
                send(frame(NODE, MYCALL, ((nr & 0x07) << 5) | 0x01))  # RR
                if b"\r" in ctext or b"}" in ctext:
                    text = ctext.decode("utf-8", "replace").strip()
                    print("PASS: the node greeted us:")
                    for line in text.splitlines():
                        print(f"    {line}")
                    send(frame(NODE, MYCALL, 0x53))  # DISC P
                    print("Disconnecting. The rig works.")
                    return 0

        if not saw_nodes and int(time.time()) % 15 == 0:
            pass

    if not saw_nodes:
        print("FAIL: no NODES broadcast heard in 150s — is linbpq up? "
              "(docker compose logs linbpq)")
    elif not connected:
        print("FAIL: NODES heard but the SABM went unanswered.")
    else:
        print("FAIL: connected but no CTEXT arrived.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
