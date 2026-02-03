#!/usr/bin/env python3
"""
AXTerm Interactive Visual Test Console

An interactive terminal interface where you can type messages as either
station and watch them flow through the relay in real-time.

Usage:
    ./interactive-test.py

Commands:
    /a <message>  - Send message from Station A
    /b <message>  - Send message from Station B
    /axdp <msg>   - Send AXDP chat message from A to B
    /sabm         - Send SABM from A to B
    /ping         - Send ping from A to B
    /stress <n>   - Send n rapid frames
    /clear        - Clear the display
    /quit         - Exit

Author: AXTerm Development
"""

import asyncio
import os
import signal
import socket
import struct
import sys
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional, List, Deque
import select

try:
    from rich.console import Console
    from rich.layout import Layout
    from rich.live import Live
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
    from rich import box
    from rich.prompt import Prompt
except ImportError:
    print("This script requires the 'rich' library.")
    print("Install with: pip install rich")
    sys.exit(1)

# =============================================================================
# Constants (same as visual-test.py)
# =============================================================================

KISS_FEND = 0xC0
KISS_FESC = 0xDB
KISS_TFEND = 0xDC
KISS_TFESC = 0xDD
AXDP_MAGIC = b"AXT1"

FRAME_COLORS = {
    "UI": "green",
    "SABM": "yellow",
    "UA": "cyan",
    "DM": "red",
    "DISC": "magenta",
    "I": "blue",
    "RR": "white",
    "AXDP": "bright_magenta",
    "?": "dim",
}

# =============================================================================
# KISS/AX.25 Utilities (same as visual-test.py)
# =============================================================================

def kiss_escape(data: bytes) -> bytes:
    result = bytearray()
    for byte in data:
        if byte == KISS_FEND:
            result.extend([KISS_FESC, KISS_TFEND])
        elif byte == KISS_FESC:
            result.extend([KISS_FESC, KISS_TFESC])
        else:
            result.append(byte)
    return bytes(result)

def kiss_unescape(data: bytes) -> bytes:
    result = bytearray()
    i = 0
    while i < len(data):
        if data[i] == KISS_FESC and i + 1 < len(data):
            if data[i + 1] == KISS_TFEND:
                result.append(KISS_FEND)
            elif data[i + 1] == KISS_TFESC:
                result.append(KISS_FESC)
            else:
                result.append(data[i + 1])
            i += 2
        else:
            result.append(data[i])
            i += 1
    return bytes(result)

def build_kiss_frame(ax25_data: bytes, port: int = 0) -> bytes:
    cmd = (port << 4) | 0x00
    escaped = kiss_escape(ax25_data)
    return bytes([KISS_FEND, cmd]) + escaped + bytes([KISS_FEND])

def encode_ax25_address(callsign: str, ssid: int, is_last: bool) -> bytes:
    call = callsign.upper().ljust(6)[:6]
    data = bytearray()
    for c in call:
        data.append(ord(c) << 1)
    ssid_byte = 0x60 | ((ssid & 0x0F) << 1)
    if is_last:
        ssid_byte |= 0x01
    data.append(ssid_byte)
    return bytes(data)

def decode_frame_type(control: int) -> tuple:
    if (control & 0x01) == 0:
        ns = (control >> 1) & 0x07
        nr = (control >> 5) & 0x07
        pf = (control >> 4) & 0x01
        return "I", f"N(S)={ns} N(R)={nr}"
    elif (control & 0x03) == 0x01:
        s_type = (control >> 2) & 0x03
        nr = (control >> 5) & 0x07
        s_names = {0: "RR", 1: "RNR", 2: "REJ", 3: "SREJ"}
        return s_names.get(s_type, "S?"), f"N(R)={nr}"
    else:
        u_type = control & 0xEF
        u_names = {
            0x2F: "SABM", 0x0F: "DM", 0x43: "DISC",
            0x63: "UA", 0x03: "UI", 0x87: "FRMR"
        }
        return u_names.get(u_type, f"U?"), ""

def decode_ax25_frame(data: bytes) -> dict:
    result = {
        "source": "?", "dest": "?", "via": [],
        "frame_type": "?", "details": "",
        "payload": b"", "is_axdp": False,
    }

    if len(data) < 14:
        return result

    # Decode addresses
    def decode_addr(d, off):
        if len(d) < off + 7:
            return "?", 0, True, off
        call = "".join(chr((d[off + i] >> 1) & 0x7F) for i in range(6)).strip()
        ssid = (d[off + 6] >> 1) & 0x0F
        is_last = bool(d[off + 6] & 0x01)
        return f"{call}-{ssid}" if ssid else call, ssid, is_last, off + 7

    result["dest"], _, _, offset = decode_addr(data, 0)
    result["source"], _, is_last, offset = decode_addr(data, 7)

    while not is_last and offset + 7 <= len(data):
        via, _, is_last, offset = decode_addr(data, offset)
        result["via"].append(via)

    if offset < len(data):
        control = data[offset]
        ft, details = decode_frame_type(control)
        result["frame_type"] = ft
        result["details"] = details
        offset += 1

        if ft in ("I", "UI") and offset < len(data):
            offset += 1  # Skip PID
            if offset < len(data):
                result["payload"] = data[offset:]
                if result["payload"].startswith(AXDP_MAGIC):
                    result["is_axdp"] = True
                    result["frame_type"] = "AXDP"

    return result

def build_ui_frame(source: str, dest: str, payload: bytes) -> bytes:
    frame = bytearray()

    src_parts = source.upper().split("-")
    dst_parts = dest.upper().split("-")

    frame.extend(encode_ax25_address(dst_parts[0], int(dst_parts[1]) if len(dst_parts) > 1 else 0, False))
    frame.extend(encode_ax25_address(src_parts[0], int(src_parts[1]) if len(src_parts) > 1 else 0, True))
    frame.append(0x03)  # UI
    frame.append(0xF0)  # PID
    frame.extend(payload)

    return bytes(frame)

def build_axdp_chat(text: str) -> bytes:
    data = bytearray(AXDP_MAGIC)
    data.append(0x01)
    data.extend(struct.pack(">H", 1))
    data.append(0x01)
    data.append(0x02)
    data.extend(struct.pack(">H", 2))
    data.extend(struct.pack(">H", 0))
    msg_id = int(time.time() * 1000) & 0xFFFFFFFF
    data.append(0x03)
    data.extend(struct.pack(">H", 4))
    data.extend(struct.pack(">I", msg_id))
    text_bytes = text.encode("utf-8")
    data.append(0x06)
    data.extend(struct.pack(">H", len(text_bytes)))
    data.extend(text_bytes)
    return bytes(data)

def build_sabm(source: str, dest: str) -> bytes:
    frame = bytearray()
    src_parts = source.upper().split("-")
    dst_parts = dest.upper().split("-")
    frame.extend(encode_ax25_address(dst_parts[0], int(dst_parts[1]) if len(dst_parts) > 1 else 0, False))
    frame.extend(encode_ax25_address(src_parts[0], int(src_parts[1]) if len(src_parts) > 1 else 0, True))
    frame.append(0x3F)
    return bytes(frame)

# =============================================================================
# Frame Event Log
# =============================================================================

@dataclass
class FrameEvent:
    timestamp: datetime
    direction: str
    station: str
    frame_type: str
    source: str
    dest: str
    payload_preview: str
    size: int
    is_axdp: bool = False

# =============================================================================
# Station
# =============================================================================

class Station:
    def __init__(self, name: str, callsign: str, host: str, port: int):
        self.name = name
        self.callsign = callsign
        self.host = host
        self.port = port
        self.socket: Optional[socket.socket] = None
        self.running = False
        self.events: Deque[FrameEvent] = deque(maxlen=100)
        self.tx_count = 0
        self.rx_count = 0
        self.parser_buffer = bytearray()
        self.in_frame = False
        self._receive_thread = None

    def connect(self) -> bool:
        try:
            self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.socket.settimeout(5.0)
            self.socket.connect((self.host, self.port))
            self.socket.settimeout(0.1)
            self.running = True
            self._receive_thread = threading.Thread(target=self._receive_loop, daemon=True)
            self._receive_thread.start()
            return True
        except Exception as e:
            return False

    def disconnect(self):
        self.running = False
        if self.socket:
            try:
                self.socket.close()
            except:
                pass

    def send(self, ax25_frame: bytes):
        if not self.socket:
            return
        try:
            kiss_frame = build_kiss_frame(ax25_frame)
            self.socket.sendall(kiss_frame)
            self.tx_count += 1

            decoded = decode_ax25_frame(ax25_frame)
            self._log_event("TX", decoded, len(ax25_frame))
        except Exception as e:
            pass

    def send_ui(self, dest: str, payload: bytes):
        frame = build_ui_frame(self.callsign, dest, payload)
        self.send(frame)

    def send_chat(self, dest: str, text: str):
        axdp = build_axdp_chat(text)
        self.send_ui(dest, axdp)

    def _receive_loop(self):
        while self.running:
            try:
                data = self.socket.recv(4096)
                if data:
                    self._process_data(data)
            except socket.timeout:
                continue
            except:
                break

    def _process_data(self, data: bytes):
        for byte in data:
            if byte == KISS_FEND:
                if self.in_frame and len(self.parser_buffer) > 0:
                    kiss_data = bytes(self.parser_buffer)
                    if len(kiss_data) > 1:
                        ax25_data = kiss_unescape(kiss_data[1:])
                        self._handle_frame(ax25_data)
                self.parser_buffer.clear()
                self.in_frame = True
            elif self.in_frame:
                self.parser_buffer.append(byte)

    def _handle_frame(self, ax25_data: bytes):
        self.rx_count += 1
        decoded = decode_ax25_frame(ax25_data)
        self._log_event("RX", decoded, len(ax25_data))

    def _log_event(self, direction: str, decoded: dict, size: int):
        payload_preview = ""
        if decoded.get("payload"):
            try:
                p = decoded["payload"]
                if decoded.get("is_axdp") and len(p) > 20:
                    # Try to extract AXDP text
                    preview = p[20:50].decode("utf-8", errors="replace")
                else:
                    preview = p[:40].decode("utf-8", errors="replace")
                payload_preview = preview.replace("\r", "").replace("\n", " ")[:35]
            except:
                payload_preview = f"<{len(decoded['payload'])}B>"

        event = FrameEvent(
            timestamp=datetime.now(),
            direction=direction,
            station=self.name,
            frame_type=decoded.get("frame_type", "?"),
            source=decoded.get("source", "?"),
            dest=decoded.get("dest", "?"),
            payload_preview=payload_preview,
            size=size,
            is_axdp=decoded.get("is_axdp", False),
        )
        self.events.append(event)

# =============================================================================
# Interactive Console
# =============================================================================

class InteractiveConsole:
    def __init__(self):
        self.console = Console()
        self.station_a: Optional[Station] = None
        self.station_b: Optional[Station] = None
        self.running = False
        self.command_buffer = ""
        self.status_message = "Type a command or /help"

    def setup(self) -> bool:
        self.console.print("\n[bold cyan]AXTerm Interactive Test Console[/bold cyan]")
        self.console.print("=" * 60)

        self.station_a = Station("A", "TEST-1", "localhost", 8001)
        self.station_b = Station("B", "TEST-2", "localhost", 8002)

        self.console.print("[yellow]Connecting to relay...[/yellow]")

        if not self.station_a.connect():
            self.console.print("[red]Failed to connect Station A[/red]")
            return False

        if not self.station_b.connect():
            self.console.print("[red]Failed to connect Station B[/red]")
            self.station_a.disconnect()
            return False

        self.console.print("[green]Connected![/green]\n")
        return True

    def cleanup(self):
        self.running = False
        if self.station_a:
            self.station_a.disconnect()
        if self.station_b:
            self.station_b.disconnect()

    def render_events(self) -> Panel:
        """Render combined event log"""
        table = Table(show_header=True, header_style="bold", box=box.SIMPLE, expand=True)
        table.add_column("Time", style="dim", width=8)
        table.add_column("Stn", width=3)
        table.add_column("Dir", width=3)
        table.add_column("Type", width=6)
        table.add_column("Route", width=20)
        table.add_column("Payload", ratio=1)

        # Combine and sort events from both stations
        all_events = []
        if self.station_a:
            all_events.extend(self.station_a.events)
        if self.station_b:
            all_events.extend(self.station_b.events)

        all_events.sort(key=lambda e: e.timestamp)

        for event in list(all_events)[-20:]:
            time_str = event.timestamp.strftime("%H:%M:%S")
            stn_style = "green" if event.station == "A" else "blue"
            dir_style = "bold green" if event.direction == "TX" else "cyan"
            type_color = FRAME_COLORS.get(event.frame_type, "white")

            route = f"{event.source}→{event.dest}"

            table.add_row(
                time_str,
                Text(event.station, style=stn_style),
                Text(event.direction, style=dir_style),
                Text(event.frame_type, style=type_color),
                route[:20],
                event.payload_preview[:40] if event.payload_preview else "",
            )

        return Panel(table, title="Frame Log", border_style="cyan", box=box.ROUNDED)

    def render_stats(self) -> Panel:
        """Render statistics"""
        text = Text()

        if self.station_a and self.station_b:
            text.append("Station A (TEST-1): ", style="green bold")
            text.append(f"TX={self.station_a.tx_count} RX={self.station_a.rx_count}\n")
            text.append("Station B (TEST-2): ", style="blue bold")
            text.append(f"TX={self.station_b.tx_count} RX={self.station_b.rx_count}\n")

        text.append(f"\n{self.status_message}", style="dim")

        return Panel(text, title="Status", border_style="yellow", box=box.ROUNDED)

    def render_help(self) -> Panel:
        """Render help panel"""
        help_text = """[bold]Commands:[/bold]
/a <msg>     Send plain text from A to B
/b <msg>     Send plain text from B to A
/axdp <msg>  Send AXDP chat from A to B
/sabm        Send SABM from A to B
/stress <n>  Send n rapid frames
/clear       Clear event log
/quit        Exit"""

        return Panel(help_text, title="Help", border_style="magenta", box=box.ROUNDED)

    def create_layout(self) -> Layout:
        layout = Layout()
        layout.split_column(
            Layout(name="main", ratio=3),
            Layout(name="bottom", size=10),
        )
        layout["bottom"].split_row(
            Layout(name="stats", ratio=1),
            Layout(name="help", ratio=1),
        )
        return layout

    def process_command(self, cmd: str):
        """Process a user command"""
        cmd = cmd.strip()
        if not cmd:
            return

        parts = cmd.split(maxsplit=1)
        command = parts[0].lower()
        args = parts[1] if len(parts) > 1 else ""

        if command == "/a":
            if args:
                self.station_a.send_ui("TEST-2", args.encode())
                self.status_message = f"Sent from A: {args[:30]}"
            else:
                self.status_message = "Usage: /a <message>"

        elif command == "/b":
            if args:
                self.station_b.send_ui("TEST-1", args.encode())
                self.status_message = f"Sent from B: {args[:30]}"
            else:
                self.status_message = "Usage: /b <message>"

        elif command == "/axdp":
            if args:
                self.station_a.send_chat("TEST-2", args)
                self.status_message = f"AXDP chat: {args[:30]}"
            else:
                self.status_message = "Usage: /axdp <message>"

        elif command == "/sabm":
            frame = build_sabm("TEST-1", "TEST-2")
            self.station_a.send(frame)
            self.status_message = "Sent SABM from A to B"

        elif command == "/stress":
            try:
                n = int(args) if args else 10
                n = min(n, 100)
                for i in range(n):
                    self.station_a.send_ui("TEST-2", f"Stress #{i+1}".encode())
                    time.sleep(0.05)
                self.status_message = f"Sent {n} stress frames"
            except ValueError:
                self.status_message = "Usage: /stress <number>"

        elif command == "/clear":
            if self.station_a:
                self.station_a.events.clear()
            if self.station_b:
                self.station_b.events.clear()
            self.status_message = "Cleared event log"

        elif command in ("/quit", "/exit", "/q"):
            self.running = False

        elif command == "/help":
            self.status_message = "See help panel on the right"

        else:
            # Treat as plain message from A
            self.station_a.send_ui("TEST-2", cmd.encode())
            self.status_message = f"Sent: {cmd[:30]}"

    def run(self):
        if not self.setup():
            return

        self.running = True
        layout = self.create_layout()

        self.console.print("\n[dim]Type messages or commands. Use /help for commands. /quit to exit.[/dim]\n")

        try:
            while self.running:
                # Update layout
                layout["main"].update(self.render_events())
                layout["stats"].update(self.render_stats())
                layout["help"].update(self.render_help())

                # Print layout (clear and redraw)
                self.console.clear()
                self.console.print(layout)
                self.console.print("\n[bold]>[/bold] ", end="")

                # Get input with timeout
                try:
                    import sys
                    if sys.stdin in select.select([sys.stdin], [], [], 0.5)[0]:
                        line = sys.stdin.readline().strip()
                        if line:
                            self.process_command(line)
                except:
                    time.sleep(0.5)

        except KeyboardInterrupt:
            pass
        finally:
            self.cleanup()

        self.console.print("\n[green]Goodbye![/green]")


def main():
    console = InteractiveConsole()
    console.run()


if __name__ == "__main__":
    main()
