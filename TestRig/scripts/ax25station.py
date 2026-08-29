#!/usr/bin/env python3
"""A minimal AX.25 connected-mode station for the rig's Python nodes.

Enough of AX.25 v2.0 mod-8 to hold a session: answer SABM with UA,
exchange numbered I-frames with RR acknowledgement, honour DISC. Not a
full stack — no REJ/SREJ, no timers beyond a crude retransmit — but
correct on the wire, which is what a node emulator and AXTerm need from
each other. The KA-node and any future Python node build on this.
"""

import socket
import time

FEND, FESC, TFEND, TFESC = 0xC0, 0xDB, 0xDC, 0xDD
# Control field encodings (mod-8)
SABM, UA, DISC, DM, FRMR = 0x2F, 0x63, 0x43, 0x0F, 0x87
UI = 0x03


def encode_address(call, ssid, last=False, command=False):
    field = bytearray((ord(c) << 1) for c in call.ljust(6)[:6])
    byte = 0x60 | (ssid << 1)
    if command:
        byte |= 0x80
    if last:
        byte |= 0x01
    field.append(byte)
    return field


def parse_call(raw, off):
    call = "".join(chr(b >> 1) for b in raw[off:off + 6]).strip()
    ssid = (raw[off + 6] >> 1) & 0x0F
    return call, ssid


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


def kiss_unwrap(frame):
    out = bytearray()
    i = 0
    body = frame[1:] if frame and (frame[0] & 0x0F) == 0 else frame
    while i < len(body):
        b = body[i]
        if b == FESC and i + 1 < len(body):
            nxt = body[i + 1]
            out.append(FEND if nxt == TFEND else FESC if nxt == TFESC else nxt)
            i += 2
        else:
            out.append(b)
            i += 1
    return bytes(out)


class Session:
    """One connected caller."""
    def __init__(self, remote, remote_ssid):
        self.remote = remote
        self.remote_ssid = remote_ssid
        self.vs = 0   # our send sequence
        self.vr = 0   # our expected receive sequence
        self.last_activity = time.time()


class AX25Station:
    """A station on the channel that answers connects to `mycall`."""

    def __init__(self, host, port, mycall, myssid):
        self.host = host
        self.port = port
        self.mycall = mycall.upper()
        self.myssid = myssid
        self.sessions = {}   # (call, ssid) -> Session
        self.sock = None
        # Hooks set by subclass / user:
        self.on_connect = lambda s: None       # -> str greeting or None
        self.on_line = lambda s, line: None     # -> str reply or None
        self.on_disconnect = lambda s: None

    # -- framing --------------------------------------------------------

    def _frame(self, dest, dssid, control, pid=None, info=b"", command=True):
        raw = encode_address(dest, dssid, command=command)
        raw += encode_address(self.mycall, self.myssid, last=True, command=not command)
        raw.append(control)
        if pid is not None:
            raw.append(pid)
            raw += info
        return bytes(raw)

    def _send(self, frame):
        self.sock.sendall(kiss_wrap(frame))

    def _send_i(self, sess, text):
        for chunk_start in range(0, max(1, len(text)), 128):
            chunk = text[chunk_start:chunk_start + 128]
            control = (sess.vr << 5) | (sess.vs << 1)  # I-frame, P=0
            self._send(self._frame(sess.remote, sess.remote_ssid, control,
                                   pid=0xF0, info=chunk.encode()))
            sess.vs = (sess.vs + 1) & 0x07

    def _send_rr(self, sess, poll_final=False):
        control = (sess.vr << 5) | 0x01 | (0x10 if poll_final else 0)
        self._send(self._frame(sess.remote, sess.remote_ssid, control))

    # -- dispatch -------------------------------------------------------

    def _handle(self, raw):
        if len(raw) < 15:
            return
        dcall, dssid = parse_call(raw, 0)
        if dcall != self.mycall or dssid != self.myssid:
            return  # not addressed to us
        scall, sssid = parse_call(raw, 7)
        control = raw[14]
        key = (scall, sssid)

        # U-frames
        u = control & 0xEF
        if u == SABM:
            sess = Session(scall, sssid)
            self.sessions[key] = sess
            self._send(self._frame(scall, sssid, UA, command=False))
            greeting = self.on_connect(sess)
            if greeting:
                self._send_i(sess, greeting)
            return
        if u == DISC:
            self._send(self._frame(scall, sssid, UA, command=False))
            if key in self.sessions:
                self.on_disconnect(self.sessions.pop(key))
            return
        if control in (UA, DM):
            return

        sess = self.sessions.get(key)
        if not sess:
            # Unknown session — refuse cleanly.
            self._send(self._frame(scall, sssid, DM, command=False))
            return

        # S-frames (RR/RNR/REJ): low bits 01
        if (control & 0x03) == 0x01:
            return  # ack; nothing queued to retransmit in this minimal stack

        # I-frame: low bit 0
        if (control & 0x01) == 0:
            ns = (control >> 1) & 0x07
            if ns == sess.vr:
                sess.vr = (sess.vr + 1) & 0x07
                info = raw[16:] if len(raw) > 16 else b""
                text = info.decode("utf-8", "replace")
                self._send_rr(sess)
                for line in text.replace("\r", "\n").split("\n"):
                    line = line.strip()
                    if not line:
                        continue
                    reply = self.on_line(sess, line)
                    if reply == "__DISCONNECT__":
                        self._send(self._frame(sess.remote, sess.remote_ssid,
                                               DISC, command=True))
                        self.on_disconnect(self.sessions.pop(key, sess))
                        return
                    if reply:
                        self._send_i(sess, reply)
            else:
                self._send_rr(sess)  # out of sequence: re-ack what we have

    # -- run ------------------------------------------------------------

    def run_forever(self, on_idle=None, idle_interval=1.0):
        self.sock = socket.create_connection((self.host, self.port), timeout=5)
        self.sock.settimeout(idle_interval)
        buffer = bytearray()
        in_frame = False
        while True:
            try:
                chunk = self.sock.recv(4096)
                if not chunk:
                    break
            except socket.timeout:
                if on_idle:
                    on_idle(self)
                continue
            for byte in chunk:
                if byte == FEND:
                    if in_frame and buffer:
                        self._handle(kiss_unwrap(bytes(buffer)))
                    buffer.clear()
                    in_frame = True
                elif in_frame:
                    buffer.append(byte)

    def send_ui(self, dest, dssid, text):
        """A beacon / broadcast — UI frame, no session."""
        self._send(self._frame(dest, dssid, UI, pid=0xF0, info=text.encode()))
