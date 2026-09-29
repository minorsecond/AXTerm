#!/usr/bin/env python3
"""Transmit Direwolf-generated audio through Warbler, bypassing its modulator.

Warbler holds the only SCU-LAN10 session to the FT-710, so there is no second
audio path to that radio: no spare sound card on the Pi, no `snd-aloop`, and
the daemon's audio bridge is receive-only. What it does have is the path its
own web UI uses for push-to-talk -- a WebSocket at /api/tx carrying 16 kHz
stereo s16le, keyed with "key"/"unkey" text messages. Feeding Direwolf's audio
in there instead of a microphone puts Warbler's radio link on the air with
somebody else's modulator.

That is the experiment this exists for. On 2026-09-19 Warbler's own 300 bd
transmissions decoded at 4% into a receiver 32 dB out of the noise, while
AXTerm's decoded first time through a dummy load, and every measurable property
of Warbler's signal -- tones, 200 Hz shift, 300.00 baud, twist, SNR -- was
correct. If Direwolf's audio goes out through the same radio and decodes, the
radio and the path are fine and the modulator is not.

IT TRANSMITS. Check the radio's frequency and power first.

    ./warbler_tx_bypass.py --confirm --text "hello" --count 3

Run it on the machine hosting Warbler; the transmit socket is bound to
localhost.
"""
import argparse, base64, os, socket, ssl, struct, subprocess, sys, tempfile, time, wave

RATE = 16000           # what the daemon says goes on the wire
FRAME_MS = 10          # "10 ms per frame", per scu-lan10d --help


class WS:
    """The smallest WebSocket client that can do this job, so the bench needs
    nothing installed. Client frames are masked; the server's replies are not
    interesting here beyond staying open."""

    def __init__(self, host, port, path, timeout=10, tls=True):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        # The daemon serves its web port over TLS with its own certificate
        # (`tls: true` in /api/status), so a plaintext upgrade is answered with
        # a reset. Name checking is off because the certificate is issued for
        # the host's public name and this connects to localhost.
        if tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            self.sock = ctx.wrap_socket(self.sock, server_hostname=host)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                raise RuntimeError("socket closed during handshake")
            head += chunk
        if b"101" not in head.split(b"\r\n")[0]:
            raise RuntimeError("upgrade refused: " + head.split(b"\r\n")[0].decode(errors="replace"))
        self.sock.settimeout(None)

    def _send(self, opcode, payload: bytes):
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        n = len(payload)
        header = struct.pack("!B", 0x80 | opcode)
        if n < 126:
            header += struct.pack("!B", 0x80 | n)
        elif n < 65536:
            header += struct.pack("!BH", 0x80 | 126, n)
        else:
            header += struct.pack("!BQ", 0x80 | 127, n)
        self.sock.sendall(header + mask + masked)

    def text(self, s):   self._send(0x1, s.encode())
    def binary(self, b): self._send(0x2, b)
    def close(self):
        try:
            self._send(0x8, b"")
        except OSError:
            pass
        self.sock.close()


def generate(text, baud, call, dest, count, amplitude):
    """Direwolf's own modulator, written to a WAV."""
    d = tempfile.mkdtemp(prefix="warbler-bypass-")
    frames, wav = os.path.join(d, "frames.txt"), os.path.join(d, "tx.wav")
    with open(frames, "w") as f:
        for i in range(1, count + 1):
            f.write(f"{call}>{dest}:{text} {i}\n")
    subprocess.run(["gen_packets", "-B", str(baud), "-r", str(RATE),
                    "-a", str(amplitude), "-o", wav, frames],
                   check=True, capture_output=True)
    # Prove it before keying: if Direwolf cannot read its own audio there is
    # no point putting it on the air.
    got = subprocess.run(["atest", "-B", str(baud), wav], capture_output=True, text=True)
    decoded = got.stdout.count("DECODED")
    print(f"   generated {count} frame(s) at {baud} bd; atest reads back {decoded}")
    if decoded < count:
        print("   !! direwolf cannot decode its own audio -- stopping", file=sys.stderr)
        sys.exit(1)
    return wav


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", type=int, default=8710)
    p.add_argument("--baud", type=int, default=300)
    p.add_argument("--call", default="K0EPI-1")
    p.add_argument("--dest", default="CQ")
    p.add_argument("--count", type=int, default=3)
    p.add_argument("--amplitude", type=int, default=50, help="gen_packets -a; keep the rig's ALC near zero")
    p.add_argument("--text", default="BYPASS TEST A0123456789B0123456789C0123456789")
    p.add_argument("--no-tls", action="store_true", help="plaintext, if the web port is not TLS")
    p.add_argument("--confirm", action="store_true")
    a = p.parse_args()

    if not a.confirm:
        print(__doc__.split("IT TRANSMITS.")[1].strip(), file=sys.stderr)
        sys.exit(1)

    print(f"== generating with direwolf ({a.baud} bd)")
    wav = generate(a.text, a.baud, a.call, a.dest, a.count, a.amplitude)

    with wave.open(wav) as w:
        assert w.getframerate() == RATE, f"expected {RATE} Hz, got {w.getframerate()}"
        mono = w.readframes(w.getnframes())
    samples = len(mono) // 2
    print(f"== {samples/RATE:.1f}s of audio; keying {a.host}:{a.port}")

    ws = WS(a.host, a.port, "/api/tx", tls=not a.no_tls)
    per = RATE * FRAME_MS // 1000          # samples per frame
    try:
        ws.text("key")
        time.sleep(0.25)                   # let the radio actually key before audio starts
        start = time.monotonic()
        for i in range(0, samples, per):
            chunk = mono[i * 2:(i + per) * 2]
            # mono -> stereo: the UI duplicates each sample into both channels
            stereo = bytearray()
            for j in range(0, len(chunk), 2):
                stereo += chunk[j:j + 2] + chunk[j:j + 2]
            ws.binary(bytes(stereo))
            due = start + (i + per) / RATE
            slack = due - time.monotonic()
            if slack > 0:
                time.sleep(slack)
        time.sleep(0.25)                   # let the tail get out before unkeying
    finally:
        ws.text("unkey")
        time.sleep(0.1)
        ws.close()
    print("== unkeyed. Watch AXTerm on the 705, and Warbler's rxFrames stays 0 (it was transmitting).")


if __name__ == "__main__":
    main()
