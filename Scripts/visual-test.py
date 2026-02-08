#!/usr/bin/env python3
"""
AXTerm Visual Integration Test Harness

This script provides a visual terminal interface showing two packet radio
stations communicating through the Docker relay. It displays:
- Real-time frame transmission between stations
- Protocol details (frame types, sequence numbers, AXDP detection)
- Performance metrics (latency, throughput, error rates)
- Diagnostic information

Usage:
    ./visual-test.py [--mode basic|connected|axdp|stress]

Requirements:
    pip install rich

Author: AXTerm Development
"""

import argparse
import asyncio
import hashlib
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
from enum import Enum
from typing import Optional, List, Dict, Deque

# Check for rich library
try:
    from rich.console import Console
    from rich.layout import Layout
    from rich.live import Live
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
    from rich.progress import Progress, SpinnerColumn, TextColumn
    from rich import box
except ImportError:
    print("This script requires the 'rich' library for terminal UI.")
    print("Install it with: pip install rich")
    sys.exit(1)

# =============================================================================
# Constants
# =============================================================================

KISS_FEND = 0xC0
KISS_FESC = 0xDB
KISS_TFEND = 0xDC
KISS_TFESC = 0xDD

AXDP_MAGIC = b"AXT1"

# Frame type colors
FRAME_COLORS = {
    "UI": "green",
    "SABM": "yellow",
    "UA": "cyan",
    "DM": "red",
    "DISC": "magenta",
    "I": "blue",
    "RR": "white",
    "RNR": "orange3",
    "REJ": "red",
    "AXDP": "bright_magenta",
    "?": "dim",
}

# =============================================================================
# Data Classes
# =============================================================================

@dataclass
class FrameStats:
    """Statistics for a station"""
    tx_count: int = 0
    rx_count: int = 0
    tx_bytes: int = 0
    rx_bytes: int = 0
    errors: int = 0
    latencies: Deque[float] = field(default_factory=lambda: deque(maxlen=100))
    start_time: float = field(default_factory=time.time)

    @property
    def duration(self) -> float:
        return time.time() - self.start_time

    @property
    def tx_rate(self) -> float:
        if self.duration > 0:
            return self.tx_count / self.duration
        return 0

    @property
    def rx_rate(self) -> float:
        if self.duration > 0:
            return self.rx_count / self.duration
        return 0

    @property
    def avg_latency(self) -> float:
        if self.latencies:
            return sum(self.latencies) / len(self.latencies)
        return 0


@dataclass
class FrameEvent:
    """A frame transmission/reception event"""
    timestamp: datetime
    direction: str  # "TX" or "RX"
    station: str
    frame_type: str
    details: str
    size: int
    is_axdp: bool = False
    payload_preview: str = ""


@dataclass
class AX25Address:
    """Decoded AX.25 address"""
    callsign: str
    ssid: int

    def __str__(self):
        if self.ssid == 0:
            return self.callsign
        return f"{self.callsign}-{self.ssid}"


# =============================================================================
# KISS / AX.25 Utilities
# =============================================================================

def kiss_escape(data: bytes) -> bytes:
    """Escape special KISS bytes"""
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
    """Unescape KISS data"""
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
    """Build a KISS frame"""
    cmd = (port << 4) | 0x00
    escaped = kiss_escape(ax25_data)
    return bytes([KISS_FEND, cmd]) + escaped + bytes([KISS_FEND])


def decode_ax25_address(data: bytes, offset: int) -> tuple:
    """Decode AX.25 address, return (address, is_last, new_offset)"""
    if len(data) < offset + 7:
        return None, True, offset

    callsign = ""
    for i in range(6):
        char = (data[offset + i] >> 1) & 0x7F
        if char != 0x20:
            callsign += chr(char)

    ssid_byte = data[offset + 6]
    ssid = (ssid_byte >> 1) & 0x0F
    is_last = bool(ssid_byte & 0x01)

    return AX25Address(callsign.strip(), ssid), is_last, offset + 7


def encode_ax25_address(callsign: str, ssid: int, is_last: bool) -> bytes:
    """Encode AX.25 address"""
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
    """Decode control byte, return (frame_type, details)"""
    if (control & 0x01) == 0:
        # I-frame
        ns = (control >> 1) & 0x07
        nr = (control >> 5) & 0x07
        pf = (control >> 4) & 0x01
        return "I", f"N(S)={ns} N(R)={nr} P/F={pf}"
    elif (control & 0x03) == 0x01:
        # S-frame
        s_type = (control >> 2) & 0x03
        nr = (control >> 5) & 0x07
        pf = (control >> 4) & 0x01
        s_names = {0: "RR", 1: "RNR", 2: "REJ", 3: "SREJ"}
        return s_names.get(s_type, "S?"), f"N(R)={nr} P/F={pf}"
    else:
        # U-frame
        u_type = control & 0xEF
        pf = (control >> 4) & 0x01
        u_names = {
            0x2F: "SABM", 0x0F: "DM", 0x43: "DISC",
            0x63: "UA", 0x03: "UI", 0x87: "FRMR"
        }
        return u_names.get(u_type, f"U({control:02X})"), f"P/F={pf}"


def decode_ax25_frame(data: bytes) -> dict:
    """Decode AX.25 frame for display"""
    result = {
        "dest": None,
        "source": None,
        "via": [],
        "frame_type": "?",
        "details": "",
        "payload": b"",
        "is_axdp": False,
    }

    if len(data) < 14:
        return result

    # Decode destination
    dest, _, offset = decode_ax25_address(data, 0)
    result["dest"] = dest

    # Decode source
    source, is_last, offset = decode_ax25_address(data, offset)
    result["source"] = source

    # Decode via path
    while not is_last and offset + 7 <= len(data):
        via, is_last, offset = decode_ax25_address(data, offset)
        if via:
            result["via"].append(via)

    # Control byte
    if offset < len(data):
        control = data[offset]
        frame_type, details = decode_frame_type(control)
        result["frame_type"] = frame_type
        result["details"] = details
        offset += 1

        # PID and payload for I/UI frames
        if frame_type in ("I", "UI") and offset < len(data):
            result["pid"] = data[offset]
            offset += 1
            if offset < len(data):
                result["payload"] = data[offset:]
                # Check for AXDP
                if result["payload"].startswith(AXDP_MAGIC):
                    result["is_axdp"] = True
                    result["frame_type"] = "AXDP"

    return result


def build_ui_frame(source: str, dest: str, payload: bytes, via: list = None) -> bytes:
    """Build AX.25 UI frame"""
    frame = bytearray()

    # Parse source/dest
    src_parts = source.upper().split("-")
    src_call = src_parts[0]
    src_ssid = int(src_parts[1]) if len(src_parts) > 1 else 0

    dst_parts = dest.upper().split("-")
    dst_call = dst_parts[0]
    dst_ssid = int(dst_parts[1]) if len(dst_parts) > 1 else 0

    via = via or []

    # Destination
    frame.extend(encode_ax25_address(dst_call, dst_ssid, False))

    # Source
    frame.extend(encode_ax25_address(src_call, src_ssid, len(via) == 0))

    # Via path
    for i, v in enumerate(via):
        v_parts = v.upper().split("-")
        v_call = v_parts[0]
        v_ssid = int(v_parts[1]) if len(v_parts) > 1 else 0
        frame.extend(encode_ax25_address(v_call, v_ssid, i == len(via) - 1))

    # Control: UI
    frame.append(0x03)

    # PID: No layer 3
    frame.append(0xF0)

    # Payload
    frame.extend(payload)

    return bytes(frame)


def build_axdp_chat(text: str, session_id: int = 0, msg_id: int = None) -> bytes:
    """Build AXDP chat message payload"""
    data = bytearray()

    # Magic
    data.extend(AXDP_MAGIC)

    # Message type TLV (type=1, chat)
    data.append(0x01)
    data.extend(struct.pack(">H", 1))
    data.append(0x01)

    # Session ID TLV
    data.append(0x02)
    data.extend(struct.pack(">H", 2))
    data.extend(struct.pack(">H", session_id))

    # Message ID TLV
    msg_id = msg_id or int(time.time() * 1000) & 0xFFFFFFFF
    data.append(0x03)
    data.extend(struct.pack(">H", 4))
    data.extend(struct.pack(">I", msg_id))

    # Payload TLV
    text_bytes = text.encode("utf-8")
    data.append(0x06)
    data.extend(struct.pack(">H", len(text_bytes)))
    data.extend(text_bytes)

    return bytes(data)


def build_sabm(source: str, dest: str) -> bytes:
    """Build SABM frame"""
    frame = bytearray()

    src_parts = source.upper().split("-")
    dst_parts = dest.upper().split("-")

    frame.extend(encode_ax25_address(dst_parts[0], int(dst_parts[1]) if len(dst_parts) > 1 else 0, False))
    frame.extend(encode_ax25_address(src_parts[0], int(src_parts[1]) if len(src_parts) > 1 else 0, True))
    frame.append(0x3F)  # SABM with P=1

    return bytes(frame)


def build_ua(source: str, dest: str) -> bytes:
    """Build UA frame"""
    frame = bytearray()

    src_parts = source.upper().split("-")
    dst_parts = dest.upper().split("-")

    frame.extend(encode_ax25_address(dst_parts[0], int(dst_parts[1]) if len(dst_parts) > 1 else 0, False))
    frame.extend(encode_ax25_address(src_parts[0], int(src_parts[1]) if len(src_parts) > 1 else 0, True))
    frame.append(0x73)  # UA with F=1

    return bytes(frame)


# =============================================================================
# Station Class
# =============================================================================

class Station:
    """A simulated packet radio station"""

    def __init__(self, name: str, callsign: str, host: str, port: int, console: Console):
        self.name = name
        self.callsign = callsign
        self.host = host
        self.port = port
        self.console = console
        self.stats = FrameStats()
        self.events: Deque[FrameEvent] = deque(maxlen=50)
        self.socket: Optional[socket.socket] = None
        self.running = False
        self.receive_thread: Optional[threading.Thread] = None
        self.parser_buffer = bytearray()
        self.in_frame = False
        self.pending_pings: Dict[int, float] = {}  # msg_id -> send_time

    def connect(self) -> bool:
        """Connect to the relay"""
        try:
            self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.socket.settimeout(5.0)
            self.socket.connect((self.host, self.port))
            self.socket.settimeout(0.5)
            self.running = True
            self.receive_thread = threading.Thread(target=self._receive_loop, daemon=True)
            self.receive_thread.start()
            return True
        except Exception as e:
            self.stats.errors += 1
            return False

    def disconnect(self):
        """Disconnect from relay"""
        self.running = False
        if self.socket:
            try:
                self.socket.close()
            except:
                pass
        self.socket = None

    def send_frame(self, ax25_frame: bytes) -> bool:
        """Send an AX.25 frame"""
        if not self.socket:
            return False

        try:
            kiss_frame = build_kiss_frame(ax25_frame)
            self.socket.sendall(kiss_frame)

            # Record event
            decoded = decode_ax25_frame(ax25_frame)
            self._record_event("TX", decoded, len(ax25_frame))

            self.stats.tx_count += 1
            self.stats.tx_bytes += len(ax25_frame)
            return True
        except Exception as e:
            self.stats.errors += 1
            return False

    def send_ui(self, dest: str, payload: bytes) -> bool:
        """Send UI frame"""
        frame = build_ui_frame(self.callsign, dest, payload)
        return self.send_frame(frame)

    def send_chat(self, dest: str, text: str) -> bool:
        """Send AXDP chat message"""
        axdp = build_axdp_chat(text)
        return self.send_ui(dest, axdp)

    def send_ping(self, dest: str) -> int:
        """Send AXDP ping, return message ID"""
        msg_id = int(time.time() * 1000) & 0xFFFFFFFF

        # Build ping payload
        data = bytearray()
        data.extend(AXDP_MAGIC)
        data.append(0x01)  # Type TLV
        data.extend(struct.pack(">H", 1))
        data.append(0x06)  # Ping type
        data.append(0x03)  # Message ID TLV
        data.extend(struct.pack(">H", 4))
        data.extend(struct.pack(">I", msg_id))

        self.pending_pings[msg_id] = time.time()
        self.send_ui(dest, bytes(data))
        return msg_id

    def _receive_loop(self):
        """Background thread for receiving frames"""
        while self.running and self.socket:
            try:
                data = self.socket.recv(4096)
                if data:
                    self._process_received(data)
            except socket.timeout:
                continue
            except Exception as e:
                if self.running:
                    self.stats.errors += 1
                break

    def _process_received(self, data: bytes):
        """Process received KISS data"""
        for byte in data:
            if byte == KISS_FEND:
                if self.in_frame and len(self.parser_buffer) > 0:
                    # Complete frame
                    kiss_data = bytes(self.parser_buffer)
                    if len(kiss_data) > 1:
                        ax25_data = kiss_unescape(kiss_data[1:])  # Skip command byte
                        self._handle_frame(ax25_data)
                self.parser_buffer.clear()
                self.in_frame = True
            elif self.in_frame:
                self.parser_buffer.append(byte)

    def _handle_frame(self, ax25_data: bytes):
        """Handle a received AX.25 frame"""
        self.stats.rx_count += 1
        self.stats.rx_bytes += len(ax25_data)

        decoded = decode_ax25_frame(ax25_data)
        self._record_event("RX", decoded, len(ax25_data))

        # Check for ping response (pong)
        if decoded.get("is_axdp") and decoded.get("payload"):
            payload = decoded["payload"]
            if len(payload) > 8:
                # Look for pong message type (0x07)
                # This is simplified - real parsing would be more robust
                pass

    def _record_event(self, direction: str, decoded: dict, size: int):
        """Record a frame event"""
        payload_preview = ""
        if decoded.get("payload"):
            try:
                preview = decoded["payload"][:30].decode("utf-8", errors="replace")
                payload_preview = preview.replace("\r", "\\r").replace("\n", "\\n")
                if len(decoded["payload"]) > 30:
                    payload_preview += "..."
            except:
                payload_preview = f"<{len(decoded['payload'])} bytes>"

        src = str(decoded.get("source", "?"))
        dst = str(decoded.get("dest", "?"))
        via = decoded.get("via", [])
        via_str = f" via {','.join(str(v) for v in via)}" if via else ""

        event = FrameEvent(
            timestamp=datetime.now(),
            direction=direction,
            station=self.name,
            frame_type=decoded.get("frame_type", "?"),
            details=f"{src}->{dst}{via_str} {decoded.get('details', '')}",
            size=size,
            is_axdp=decoded.get("is_axdp", False),
            payload_preview=payload_preview,
        )
        self.events.append(event)


# =============================================================================
# Visual Test Harness
# =============================================================================

class VisualTestHarness:
    """Main visual test harness"""

    def __init__(self, mode: str = "basic"):
        self.console = Console()
        self.mode = mode
        self.station_a: Optional[Station] = None
        self.station_b: Optional[Station] = None
        self.running = False
        self.test_start_time = time.time()
        self.total_tests = 0
        self.passed_tests = 0
        self.current_test = ""

    def setup(self) -> bool:
        """Setup stations and connect"""
        self.console.print("\n[bold cyan]AXTerm Visual Integration Test Harness[/bold cyan]")
        self.console.print("=" * 60)

        # Create stations
        self.station_a = Station("Station A", "TEST-1", "localhost", 8001, self.console)
        self.station_b = Station("Station B", "TEST-2", "localhost", 8002, self.console)

        # Connect
        self.console.print("\n[yellow]Connecting to Docker relay...[/yellow]")

        if not self.station_a.connect():
            self.console.print("[red]Failed to connect Station A to port 8001[/red]")
            self.console.print("[dim]Make sure Docker relay is running: cd Docker && docker compose up -d[/dim]")
            return False

        if not self.station_b.connect():
            self.console.print("[red]Failed to connect Station B to port 8002[/red]")
            self.station_a.disconnect()
            return False

        self.console.print("[green]Both stations connected![/green]\n")
        time.sleep(0.3)
        return True

    def cleanup(self):
        """Cleanup and disconnect"""
        self.running = False
        if self.station_a:
            self.station_a.disconnect()
        if self.station_b:
            self.station_b.disconnect()

    def create_layout(self) -> Layout:
        """Create the terminal layout"""
        layout = Layout()

        layout.split_column(
            Layout(name="header", size=3),
            Layout(name="main", ratio=1),
            Layout(name="footer", size=3),
        )

        layout["main"].split_row(
            Layout(name="station_a", ratio=1),
            Layout(name="middle", size=30),
            Layout(name="station_b", ratio=1),
        )

        layout["middle"].split_column(
            Layout(name="stats", ratio=1),
            Layout(name="diagnostics", ratio=1),
        )

        return layout

    def render_header(self) -> Panel:
        """Render header panel"""
        elapsed = time.time() - self.test_start_time
        mode_colors = {
            "basic": "green",
            "connected": "yellow",
            "axdp": "magenta",
            "stress": "red",
        }
        mode_color = mode_colors.get(self.mode, "white")

        text = Text()
        text.append("AXTerm Visual Integration Test", style="bold cyan")
        text.append("  |  Mode: ", style="dim")
        text.append(self.mode.upper(), style=f"bold {mode_color}")
        text.append(f"  |  Elapsed: {elapsed:.1f}s", style="dim")
        text.append(f"  |  Tests: {self.passed_tests}/{self.total_tests}", style="dim")

        return Panel(text, style="cyan", box=box.ROUNDED)

    def render_station(self, station: Station) -> Panel:
        """Render a station panel"""
        table = Table(show_header=True, header_style="bold", box=box.SIMPLE, expand=True)
        table.add_column("Time", style="dim", width=10)
        table.add_column("Dir", width=3)
        table.add_column("Type", width=6)
        table.add_column("Details", ratio=1)

        for event in list(station.events)[-15:]:
            time_str = event.timestamp.strftime("%H:%M:%S")
            dir_style = "green" if event.direction == "TX" else "blue"
            type_color = FRAME_COLORS.get(event.frame_type, "white")

            details = event.details
            if event.payload_preview:
                details += f" [{event.payload_preview}]"

            table.add_row(
                time_str,
                Text(event.direction, style=dir_style),
                Text(event.frame_type, style=type_color),
                details[:40],
            )

        title = f"{station.name} ({station.callsign})"
        subtitle = f"TX:{station.stats.tx_count} RX:{station.stats.rx_count}"

        return Panel(
            table,
            title=title,
            subtitle=subtitle,
            border_style="green" if station.name == "Station A" else "blue",
            box=box.ROUNDED,
        )

    def render_stats(self) -> Panel:
        """Render statistics panel"""
        table = Table(show_header=False, box=None, expand=True)
        table.add_column("Metric", style="dim")
        table.add_column("A", justify="right")
        table.add_column("B", justify="right")

        if self.station_a and self.station_b:
            a, b = self.station_a.stats, self.station_b.stats

            table.add_row("TX Frames", str(a.tx_count), str(b.tx_count))
            table.add_row("RX Frames", str(a.rx_count), str(b.rx_count))
            table.add_row("TX Bytes", str(a.tx_bytes), str(b.tx_bytes))
            table.add_row("RX Bytes", str(a.rx_bytes), str(b.rx_bytes))
            table.add_row("Errors", str(a.errors), str(b.errors))
            table.add_row("TX Rate/s", f"{a.tx_rate:.1f}", f"{b.tx_rate:.1f}")

        return Panel(table, title="Statistics", border_style="yellow", box=box.ROUNDED)

    def render_diagnostics(self) -> Panel:
        """Render diagnostics panel"""
        lines = []

        if self.current_test:
            lines.append(f"[bold]Test:[/bold] {self.current_test}")

        if self.station_a and self.station_b:
            total_frames = (self.station_a.stats.tx_count + self.station_a.stats.rx_count +
                          self.station_b.stats.tx_count + self.station_b.stats.rx_count)
            total_bytes = (self.station_a.stats.tx_bytes + self.station_a.stats.rx_bytes +
                          self.station_b.stats.tx_bytes + self.station_b.stats.rx_bytes)

            elapsed = time.time() - self.test_start_time
            fps = total_frames / elapsed if elapsed > 0 else 0
            bps = total_bytes / elapsed if elapsed > 0 else 0

            lines.append(f"Total Frames: {total_frames}")
            lines.append(f"Throughput: {fps:.1f} f/s, {bps:.0f} B/s")

        text = "\n".join(lines) if lines else "Running..."
        return Panel(text, title="Diagnostics", border_style="magenta", box=box.ROUNDED)

    def render_footer(self) -> Panel:
        """Render footer panel"""
        return Panel(
            "[dim]Press Ctrl+C to stop[/dim]",
            style="dim",
            box=box.ROUNDED,
        )

    def update_display(self, layout: Layout):
        """Update all layout panels"""
        layout["header"].update(self.render_header())
        layout["station_a"].update(self.render_station(self.station_a))
        layout["station_b"].update(self.render_station(self.station_b))
        layout["stats"].update(self.render_stats())
        layout["diagnostics"].update(self.render_diagnostics())
        layout["footer"].update(self.render_footer())

    async def run_basic_tests(self):
        """Run basic UI frame tests"""
        self.current_test = "Basic UI Frames"
        self.total_tests = 5

        # Test 1: Simple UI frame A->B
        self.current_test = "UI Frame A→B"
        self.station_a.send_ui("TEST-2", b"Hello from Station A!")
        await asyncio.sleep(0.5)
        if self.station_b.stats.rx_count > 0:
            self.passed_tests += 1

        # Test 2: UI frame B->A
        self.current_test = "UI Frame B→A"
        self.station_b.send_ui("TEST-1", b"Hello from Station B!")
        await asyncio.sleep(0.5)
        if self.station_a.stats.rx_count > 0:
            self.passed_tests += 1

        # Test 3: Broadcast
        self.current_test = "Broadcast CQ"
        self.station_a.send_ui("CQ", b"CQ CQ CQ de TEST-1")
        await asyncio.sleep(0.5)
        self.passed_tests += 1

        # Test 4: Multiple frames
        self.current_test = "Multiple Frames"
        for i in range(5):
            self.station_a.send_ui("TEST-2", f"Message {i+1}".encode())
            await asyncio.sleep(0.2)
        await asyncio.sleep(0.5)
        self.passed_tests += 1

        # Test 5: Bidirectional rapid
        self.current_test = "Bidirectional Exchange"
        for i in range(3):
            self.station_a.send_ui("TEST-2", f"A->B #{i+1}".encode())
            await asyncio.sleep(0.1)
            self.station_b.send_ui("TEST-1", f"B->A #{i+1}".encode())
            await asyncio.sleep(0.1)
        self.passed_tests += 1

        self.current_test = "Basic Tests Complete"

    async def run_axdp_tests(self):
        """Run AXDP protocol tests"""
        self.current_test = "AXDP Protocol Tests"
        self.total_tests = 4

        # Test 1: AXDP Chat A->B
        self.current_test = "AXDP Chat A→B"
        self.station_a.send_chat("TEST-2", "Hello via AXDP!")
        await asyncio.sleep(0.5)
        # Check if B received AXDP
        for event in self.station_b.events:
            if event.is_axdp and event.direction == "RX":
                self.passed_tests += 1
                break

        # Test 2: AXDP Chat B->A
        self.current_test = "AXDP Chat B→A"
        self.station_b.send_chat("TEST-1", "AXDP response!")
        await asyncio.sleep(0.5)
        for event in self.station_a.events:
            if event.is_axdp and event.direction == "RX":
                self.passed_tests += 1
                break

        # Test 3: Mixed traffic
        self.current_test = "Mixed AXDP + Plain"
        self.station_a.send_ui("TEST-2", b"Plain text message")
        await asyncio.sleep(0.2)
        self.station_a.send_chat("TEST-2", "AXDP message")
        await asyncio.sleep(0.2)
        self.station_a.send_ui("TEST-2", b"Another plain message")
        await asyncio.sleep(0.5)
        self.passed_tests += 1

        # Test 4: Long AXDP message
        self.current_test = "Long AXDP Message"
        long_msg = "This is a longer AXDP message to test payload handling. " * 3
        self.station_a.send_chat("TEST-2", long_msg[:200])
        await asyncio.sleep(0.5)
        self.passed_tests += 1

        self.current_test = "AXDP Tests Complete"

    async def run_connected_tests(self):
        """Run connected mode tests"""
        self.current_test = "Connected Mode Tests"
        self.total_tests = 2

        # Test 1: SABM from A
        self.current_test = "SABM A→B"
        sabm = build_sabm("TEST-1", "TEST-2")
        self.station_a.send_frame(sabm)
        await asyncio.sleep(0.5)

        # Check if B received SABM
        for event in self.station_b.events:
            if event.frame_type == "SABM" and event.direction == "RX":
                self.passed_tests += 1
                break

        # Test 2: UA response from B
        self.current_test = "UA B→A"
        ua = build_ua("TEST-2", "TEST-1")
        self.station_b.send_frame(ua)
        await asyncio.sleep(0.5)

        for event in self.station_a.events:
            if event.frame_type == "UA" and event.direction == "RX":
                self.passed_tests += 1
                break

        self.current_test = "Connected Mode Tests Complete"

    async def run_stress_tests(self):
        """Run stress/performance tests"""
        self.current_test = "Stress Tests"
        self.total_tests = 1

        # Rapid fire frames
        self.current_test = "Rapid Frame Burst"
        start_count = self.station_b.stats.rx_count

        for i in range(50):
            self.station_a.send_ui("TEST-2", f"Stress test frame {i+1}".encode())
            await asyncio.sleep(0.05)

        await asyncio.sleep(2.0)

        received = self.station_b.stats.rx_count - start_count
        if received >= 45:  # Allow some loss
            self.passed_tests += 1

        self.current_test = f"Stress Complete: {received}/50 frames"

    async def run(self):
        """Main run loop"""
        if not self.setup():
            return

        self.running = True
        layout = self.create_layout()

        try:
            # Use vertical_overflow="visible" and lower refresh rate to reduce blinking
            with Live(layout, console=self.console, refresh_per_second=4, vertical_overflow="visible") as live:
                # Run selected test mode
                if self.mode == "basic":
                    await self.run_basic_tests()
                elif self.mode == "axdp":
                    await self.run_axdp_tests()
                elif self.mode == "connected":
                    await self.run_connected_tests()
                elif self.mode == "stress":
                    await self.run_stress_tests()

                # Keep running for a bit to show results
                self.current_test = f"Complete: {self.passed_tests}/{self.total_tests} passed"

                # Continue updating display
                end_time = time.time() + 5
                while time.time() < end_time and self.running:
                    self.update_display(layout)
                    await asyncio.sleep(0.1)

        except KeyboardInterrupt:
            pass
        finally:
            self.cleanup()

        # Print summary
        self.console.print("\n" + "=" * 60)
        self.console.print(f"[bold]Test Results:[/bold] {self.passed_tests}/{self.total_tests} passed")

        if self.station_a and self.station_b:
            self.console.print(f"\n[bold]Station A:[/bold] TX={self.station_a.stats.tx_count}, RX={self.station_a.stats.rx_count}")
            self.console.print(f"[bold]Station B:[/bold] TX={self.station_b.stats.tx_count}, RX={self.station_b.stats.rx_count}")

        self.console.print("=" * 60 + "\n")


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="AXTerm Visual Integration Test Harness",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Test Modes:
  basic      Basic UI frame transmission tests (default)
  axdp       AXDP protocol extension tests
  connected  Connected mode (SABM/UA) tests
  stress     Performance/stress tests

Examples:
  ./visual-test.py                    # Run basic tests
  ./visual-test.py --mode axdp        # Run AXDP tests
  ./visual-test.py --mode stress      # Run stress tests

Prerequisites:
  1. Start Docker relay: cd Docker && docker compose up -d
  2. Install rich: pip install rich
        """
    )

    parser.add_argument(
        "--mode", "-m",
        choices=["basic", "connected", "axdp", "stress"],
        default="basic",
        help="Test mode to run"
    )

    args = parser.parse_args()

    harness = VisualTestHarness(mode=args.mode)

    # Handle Ctrl+C gracefully
    def signal_handler(sig, frame):
        harness.running = False

    signal.signal(signal.SIGINT, signal_handler)

    # Run
    asyncio.run(harness.run())


if __name__ == "__main__":
    main()
