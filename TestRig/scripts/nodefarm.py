#!/usr/bin/env python3
"""A seed-driven farm of packet stations — 5-10 nodes of different OS
families on one channel, a different network every seed.

The point: AXTerm should behave correctly on a busy, MIXED frequency,
not just against one cooperative BPQ. Real channels carry BPQ nodes,
TheNet nodes, Kantronics KA-Nodes, dumb digipeaters, direct BBS
mailboxes, and stations that just beacon and refuse — all at once, all
different. This farm reproduces that, deterministically from a seed so
a run reproduces, and RANDOMLY across seeds so coverage broadens.

Personalities (each a real AX.25 station on the wire):
  bpq       NET/ROM node: NODES broadcast (PID 0xCF), NODES/ROUTES/MH shell
  thenet    NET/ROM node, TheNet-flavour banner + NODES broadcast
  kanode    Kantronics KA-Node: ###CONNECTED / ENTER COMMAND, NO NODES
  digi      pure digipeater: repeats via-addressed frames, ID beacon
  bbs       W0RLI/FBB mailbox answered directly, no node level
  beacon    a station that only beacons status and refuses connects (DM)

Usage:
  python3 nodefarm.py [host] [port] --seed N [--count 7]
  python3 nodefarm.py --seed N --list    # print the population, don't run
"""

import argparse
import random
import threading
import time

from ax25station import AX25Station, encode_address
from netrom import nodes_payload

CATALOG = ["bpq", "thenet", "kanode", "digi", "bbs", "beacon"]

CALLS = ["W0ARP", "K0NTS", "KB5YZB", "AB0VZ", "N0BN", "KD0SSP", "W2CRS",
         "AA3RG", "KE0GB", "N3HYM", "W0TX", "KC0LDY", "VE3CGR", "K7EK"]
ALIASES = ["DENVER", "BOULDR", "PARKER", "AURORA", "GOLDEN", "EVANS",
           "LITTLE", "CASTLE", "LOVELN", "GREELY", "PUEBLO", "ELBERT"]


def personality_for(kind, call, ssid, alias, rng):
    if kind == "bpq":
        return BPQFarmNode(call, ssid, alias, rng, flavour="bpq")
    if kind == "thenet":
        return BPQFarmNode(call, ssid, alias, rng, flavour="thenet")
    if kind == "kanode":
        return KAFarmNode(call, ssid, alias, rng)
    if kind == "digi":
        return DigiFarmNode(call, ssid, alias, rng)
    if kind == "bbs":
        return BBSFarmNode(call, ssid, alias, rng)
    return BeaconFarmNode(call, ssid, alias, rng)


class FarmStation:
    """Base: one personality, its own socket, run in a thread."""
    def __init__(self, call, ssid, alias, rng):
        self.call, self.ssid, self.alias = call, ssid, alias
        self.rng = rng
        self.station = AX25Station("", 0, call, ssid)
        self.station.on_connect = self.greet
        self.station.on_line = self.command
        self._last_beacon = 0.0
        self._beacon_every = rng.randint(20, 55)

    def label(self):
        c = f"{self.call}-{self.ssid}" if self.ssid else self.call
        return f"{c:12s} {self.alias:7s} {self.__class__.KIND}"

    def greet(self, sess):
        return None

    def command(self, sess, line):
        return None

    def idle(self, station):
        now = time.time()
        if now - self._last_beacon > self._beacon_every:
            self._last_beacon = now
            self.beacon(station)

    def beacon(self, station):
        pass

    def run(self, host, port):
        self.station.host, self.station.port = host, port
        while True:
            try:
                self.station.run_forever(on_idle=self.idle, idle_interval=1.0)
            except (ConnectionError, OSError):
                time.sleep(2)  # channel hiccup — rejoin
            except Exception as exc:  # a hostile frame must not kill a station
                print(f"   {self.call}-{self.ssid}: shrugged off {exc!r}",
                      flush=True)
                time.sleep(0.5)


class BPQFarmNode(FarmStation):
    KIND = "bpq/net-rom"

    def __init__(self, call, ssid, alias, rng, flavour="bpq"):
        super().__init__(call, ssid, alias, rng)
        self.flavour = flavour
        self.KIND = "thenet/net-rom" if flavour == "thenet" else "bpq/net-rom"
        # A couple of destinations this node claims to reach.
        self.routes = []
        for _ in range(rng.randint(1, 3)):
            dc = rng.choice(CALLS)
            self.routes.append((dc, rng.randint(1, 9), rng.choice(ALIASES),
                                call, ssid, rng.randint(80, 220)))
        self._nodes_every = rng.randint(30, 70)
        self._last_nodes = 0.0

    def greet(self, sess):
        if self.flavour == "thenet":
            return (f"{self.alias}:{self.call}-{self.ssid} TheNet X-1J4\r"
                    f"Commands: (C)onnect (N)odes (R)outes (I)nfo (B)ye\r")
        return (f"{self.alias}:{self.call}-{self.ssid} "
                f"Network Node (BPQ)\r"
                f"NODES ROUTES MH INFO CONNECT BYE\r")

    def command(self, sess, line):
        verb = line.upper().split()[0]
        prompt = f"{self.alias}:{self.call}-{self.ssid}}} "
        if verb in ("B", "BYE"):
            return "__DISCONNECT__"
        if verb in ("N", "NODES"):
            body = "  ".join(f"{a}:{c}-{s}" for c, s, a, *_ in self.routes)
            return f"Nodes: {body}\r{prompt}"
        if verb in ("R", "ROUTES"):
            rows = "\r".join(f"> 1 {c}-{s} {q} 1"
                             for c, s, _, _, _, q in self.routes)
            return f"Routes\r{rows}\r{prompt}"
        if verb in ("MH", "J"):
            return f"Heard: {self.rng.choice(CALLS)}-1\r{prompt}"
        if verb in ("I", "INFO"):
            return f"{self.alias} test-farm node ({self.flavour})\r{prompt}"
        if verb in ("C", "CONNECT"):
            return f"Not connecting onward from a test node.\r{prompt}"
        return f"? {verb}\r{prompt}"

    def beacon(self, station):
        now = time.time()
        if now - self._last_nodes > self._nodes_every:
            self._last_nodes = now
            for payload in nodes_payload(self.alias, self.routes):
                # UI frame to NODES, PID 0xCF — the real broadcast.
                self._broadcast(station, "NODES", 0, 0xCF, payload)
        station.send_ui("ID", 0,
                        f"{self.call}-{self.ssid} {self.alias} "
                        f"{self.flavour} node/N")

    def _broadcast(self, station, dcall, dssid, pid, payload):
        raw = encode_address(dcall, dssid, command=True)
        raw += encode_address(self.call, self.ssid, last=True, command=False)
        raw.append(0x03)          # UI
        raw.append(pid)
        raw += payload
        station._send(bytes(raw))


class KAFarmNode(FarmStation):
    KIND = "kantronics"

    def greet(self, sess):
        tag = f"{self.alias}({self.call}-{self.ssid})"
        return f"###CONNECTED TO NODE {tag}\rENTER COMMAND: B,C,J,N,?\r"

    def command(self, sess, line):
        verb = line.upper().split()[0]
        menu = "ENTER COMMAND: B,C,J,N,?\r"
        if verb in ("B", "BYE"):
            return "__DISCONNECT__"
        if verb in ("J", "JHEARD"):
            return f"HEARD:\r{self.rng.choice(CALLS)}-1\r{menu}"
        if verb in ("N", "NODES"):
            return f"NODES: {self.call}-{self.ssid} {self.rng.choice(CALLS)}\r{menu}"
        if verb in ("C", "CONNECT"):
            return "###LINK MADE\r"
        return f"EH?\r{menu}"

    def beacon(self, station):
        # A KA-node IDs but NEVER broadcasts NODES (PID 0xCF).
        station.send_ui("ID", 0,
                        f"{self.call}-{self.ssid}/N {self.alias} Kantronics")


class DigiFarmNode(FarmStation):
    KIND = "digipeater"

    def __init__(self, call, ssid, alias, rng):
        super().__init__(call, ssid, alias, rng)
        # A digipeater answers connects with DM (nothing to talk to) and
        # instead repeats frames addressed via it. Override the station's
        # handler to see via-addressed frames.
        self.me = f"{call.upper()}-{ssid}" if ssid else call.upper()
        self.station._handle = self._digi_handle
        self._raw_send = self.station._send

    def _digi_handle(self, raw):
        if len(raw) < 16 or (raw[13] & 0x01):
            # No digi path; if it is a connect to us, refuse with DM.
            self._maybe_dm(raw)
            return
        off = 14
        while off + 7 <= len(raw):
            repeated = raw[off + 6] & 0x80
            if not repeated:
                call = "".join(chr(b >> 1) for b in raw[off:off + 6]).strip()
                ssid = (raw[off + 6] >> 1) & 0x0F
                who = f"{call}-{ssid}" if ssid else call
                if who == self.me:
                    frame = bytearray(raw)
                    frame[off + 6] |= 0x80   # set H, repeat — correctly
                    self.station.sock.sendall(_kiss(bytes(frame)))
                return
            if raw[off + 6] & 0x01:
                return
            off += 7

    def _maybe_dm(self, raw):
        from ax25station import parse_call, DM
        if len(raw) < 15:
            return
        dcall, dssid = parse_call(raw, 0)
        if dcall == self.call and dssid == self.ssid and (raw[14] & 0xEF) == 0x2F:
            scall, sssid = parse_call(raw, 7)
            self.station._send(self.station._frame(scall, sssid, DM, command=False))

    def beacon(self, station):
        station.send_ui("ID", 0, f"{self.me} {self.alias} digipeater")


class BBSFarmNode(FarmStation):
    KIND = "bbs/mailbox"

    def greet(self, sess):
        return (f"[AXTEST-BBS-1.0]\r{self.call}-{self.ssid} BBS ready.\r"
                f"(A)bort (B)ye (L)ist (R)ead (S)end (H)elp ?\r>")

    def command(self, sess, line):
        verb = line.upper().split()[0]
        if verb in ("B", "BYE"):
            return "__DISCONNECT__"
        if verb in ("L", "LIST"):
            return "No messages.\r>"
        if verb in ("H", "HELP", "?"):
            return "A B L R S H — this is a test mailbox.\r>"
        return "?\r>"

    def beacon(self, station):
        station.send_ui("BEACON", 0,
                        f"{self.call}-{self.ssid} {self.alias} BBS - connect for mail")


class BeaconFarmNode(FarmStation):
    KIND = "beacon-only"

    def greet(self, sess):
        return None  # handled by DM below

    def __init__(self, call, ssid, alias, rng):
        super().__init__(call, ssid, alias, rng)
        # Refuse connects with DM — a station running no service.
        original = self.station._handle
        from ax25station import parse_call, DM

        def handle(raw):
            if len(raw) >= 15:
                dcall, dssid = parse_call(raw, 0)
                if (dcall == call.upper() and dssid == ssid
                        and (raw[14] & 0xEF) == 0x2F):
                    scall, sssid = parse_call(raw, 7)
                    self.station._send(self.station._frame(
                        scall, sssid, DM, command=False))
                    return
            original(raw)
        self.station._handle = handle

    def beacon(self, station):
        station.send_ui("BEACON", 0,
                        f"{self.call}-{self.ssid} {self.alias} wx station, no connects")


def _kiss(payload):
    FEND, FESC, TFEND, TFESC = 0xC0, 0xDB, 0xDC, 0xDD
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


def build_population(seed, count=None):
    rng = random.Random(seed)
    n = count if count else rng.randint(5, 10)
    calls = rng.sample(CALLS, min(n, len(CALLS)))
    aliases = rng.sample(ALIASES, min(n, len(ALIASES)))
    # Always include at least one NET/ROM node and one KA-node so the
    # classifier's two poles are present every run.
    kinds = ["bpq", "kanode"]
    while len(kinds) < n:
        kinds.append(rng.choice(CATALOG))
    rng.shuffle(kinds)
    pop = []
    for i in range(n):
        kind = kinds[i]
        ssid = rng.randint(0, 9)
        pop.append(personality_for(kind, calls[i], ssid, aliases[i], rng))
    return pop


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host", nargs="?", default="127.0.0.1")
    ap.add_argument("port", nargs="?", type=int, default=8010)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--count", type=int, default=None)
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    seed = args.seed if args.seed is not None else random.randrange(1 << 30)
    pop = build_population(seed, args.count)
    print(f"Node farm — seed {seed}, {len(pop)} stations:")
    for node in pop:
        print(f"   {node.label()}")
    if args.list:
        return

    threads = []
    for node in pop:
        t = threading.Thread(target=node.run, args=(args.host, args.port),
                             daemon=True)
        t.start()
        threads.append(t)
        time.sleep(0.2)  # stagger joins so the hub log is readable
    print("All stations on frequency. Ctrl-C to clear the channel.")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
