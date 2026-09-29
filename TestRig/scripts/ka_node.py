#!/usr/bin/env python3
"""A Kantronics KA-Node on the channel — the OTHER kind of node, the
one that is NOT a NET/ROM router.

This exists to test AXTerm's capability classifier, whose whole job is
telling a BPQ node (can carry NET/ROM circuits) apart from a KA-Node
(cannot — it digipeats and runs a command shell, nothing more). On the
real network DRLNOD is exactly this, and mistaking it for a router
poisons everything downstream.

So this node emits the Kantronics fingerprints and NOTHING that looks
like NET/ROM:
  - connect banner  "###CONNECTED TO NODE DRL(KA0TST-1)"
  - command menu     "ENTER COMMAND: B,C,J,N,?"
  - the KA verbs     C(onnect/digipeat), J(heard), N(odes list), B(ye)
  - an ID beacon with the /N node flag
  - crucially: it NEVER broadcasts a NODES table (no PID 0xCF), and its
    banner is not a BPQ "NETWORK NODE" banner.

Point AXTerm at it, or just let it beacon: DRLNOD's profile should
classify as .kaNode / not-NET/ROM-capable, with the menu quoted as
evidence.

Usage: python3 ka_node.py [host] [port] --call KA0TST --ssid 1 --alias DRL
"""

import argparse
import time

from ax25station import AX25Station

HEARD = ["W0ARP-1", "KD0SSP", "K0EPI-7", "N0BODY-2"]


def build(args):
    node = AX25Station(args.host, args.port, args.call, args.ssid)
    tag = f"{args.alias}({args.call.upper()}-{args.ssid})" if args.ssid \
        else f"{args.alias}({args.call.upper()})"

    def greet(sess):
        # The KA-node connect banner and menu — the classifier's
        # fingerprints, verbatim in spirit to a real Kantronics unit.
        return (f"###CONNECTED TO NODE {tag}\r"
                f"ENTER COMMAND: B,C,J,N,?\r")

    def line(sess, text):
        verb = text.strip().upper().split()[0] if text.strip() else ""
        if verb in ("B", "BYE"):
            return "__DISCONNECT__"
        if verb in ("J", "JHEARD", "MHEARD"):
            body = "\r".join(HEARD)
            return f"HEARD:\r{body}\rENTER COMMAND: B,C,J,N,?\r"
        if verb in ("N", "NODES"):
            # A KA-node's N is a flat neighbour list, NOT a NET/ROM
            # routing table — no aliases, no quality, no next-hop.
            return ("NODES: KA0TST-1 W0ARP-1 KD0SSP\r"
                    "ENTER COMMAND: B,C,J,N,?\r")
        if verb in ("C", "CONNECT"):
            parts = text.strip().split()
            if len(parts) < 2:
                return "C CALL - connect (digipeat) to a station\rENTER COMMAND: B,C,J,N,?\r"
            # A KA-node "connects" by digipeating; it does not bridge a
            # circuit. It says LINK MADE and would then repeat frames.
            return f"###LINK MADE\r"
        if verb == "?":
            return ("B  disconnect\rC  connect through here\r"
                    "J  stations heard\rN  neighbours\r"
                    "ENTER COMMAND: B,C,J,N,?\r")
        return f"EH? {verb}\rENTER COMMAND: B,C,J,N,?\r"

    node.on_connect = greet
    node.on_line = line

    last_id = [0.0]

    def idle(n):
        now = time.time()
        if now - last_id[0] > args.id_interval:
            last_id[0] = now
            # ID beacon with the KA-node /N flag — an identifier, never
            # a NODES broadcast.
            n.send_ui("ID", 0, f"{args.call.upper()}-{args.ssid}/N "
                               f"{args.alias} Kantronics KA-Node")

    return node, idle


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host", nargs="?", default="127.0.0.1")
    ap.add_argument("port", nargs="?", type=int, default=8010)
    ap.add_argument("--call", default="KA0TST")
    ap.add_argument("--ssid", type=int, default=1)
    ap.add_argument("--alias", default="DRL")
    ap.add_argument("--id-interval", type=float, default=30.0)
    args = ap.parse_args()

    node, idle = build(args)
    print(f"KA-Node {args.alias}({args.call.upper()}-{args.ssid}) on frequency "
          f"— NOT a NET/ROM router, by design.", flush=True)
    try:
        node.run_forever(on_idle=idle)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
