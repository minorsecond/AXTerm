#!/usr/bin/env python3
"""
AXTerm KISS Traffic Monitor

Real-time monitoring dashboard showing frame traffic between two AXTerm instances
connected through the KISS relay.

Features:
- Live frame capture and decoding
- Statistics (packets/sec, bytes, frame types)
- AX.25 frame analysis
- Connection status for both stations
- Performance metrics
"""

import socket
import threading
import time
import struct
from datetime import datetime
from collections import deque
from dataclasses import dataclass, field
from typing import Optional, List, Dict
from enum import Enum

try:
    from rich.console import Console
    from rich.live import Live
    from rich.table import Table
    from rich.layout import Layout
    from rich.panel import Panel
    from rich.text import Text
    from rich.style import Style
    from rich import box
except ImportError:
    print("Error: 'rich' library required. Install with: pip3 install rich")
    exit(1)

# KISS protocol constants
FEND = 0xC0
FESC = 0xDB
TFEND = 0xDC
TFESC = 0xDD

# AX.25 frame types
class FrameType(Enum):
    UI = "UI"       # Unnumbered Information
    I = "I"         # Information
    RR = "RR"       # Receive Ready
    RNR = "RNR"     # Receive Not Ready
    REJ = "REJ"     # Reject
    SABM = "SABM"   # Set Asynchronous Balanced Mode
    SABME = "SABME" # SABM Extended
    UA = "UA"       # Unnumbered Acknowledge
    DM = "DM"       # Disconnect Mode
    DISC = "DISC"   # Disconnect
    FRMR = "FRMR"   # Frame Reject
    XID = "XID"     # Exchange Identification
    TEST = "TEST"   # Test
    UNKNOWN = "?"


@dataclass
class DecodedFrame:
    """Decoded AX.25 frame"""
    source: str
    destination: str
    via_path: List[str]
    frame_type: FrameType
    control: int
    pid: Optional[int]
    payload: bytes
    raw: bytes
    timestamp: datetime
    direction: str  # "A→B" or "B→A"
    ns: Optional[int] = None  # N(S) for I-frames
    nr: Optional[int] = None  # N(R) for I/S-frames
    poll_final: bool = False
    is_axdp: bool = False


@dataclass
class StationStats:
    """Statistics for a station"""
    frames_sent: int = 0
    frames_received: int = 0
    bytes_sent: int = 0
    bytes_received: int = 0
    i_frames: int = 0
    s_frames: int = 0
    u_frames: int = 0
    axdp_frames: int = 0
    connected: bool = False
    last_activity: Optional[datetime] = None


class KISSDecoder:
    """KISS frame decoder with escape handling"""

    def __init__(self):
        self.buffer = bytearray()
        self.in_frame = False

    def feed(self, data: bytes) -> List[bytes]:
        """Feed data and return complete frames"""
        frames = []
        for byte in data:
            if byte == FEND:
                if self.in_frame and len(self.buffer) > 0:
                    frames.append(bytes(self.buffer))
                self.buffer = bytearray()
                self.in_frame = True
            elif self.in_frame:
                if byte == FESC:
                    pass  # Wait for next byte
                elif len(self.buffer) > 0 and self.buffer[-1] == FESC:
                    self.buffer = self.buffer[:-1]
                    if byte == TFEND:
                        self.buffer.append(FEND)
                    elif byte == TFESC:
                        self.buffer.append(FESC)
                else:
                    self.buffer.append(byte)
        return frames


class AX25Decoder:
    """AX.25 frame decoder"""

    AXDP_MAGIC = b'AXT1'

    @staticmethod
    def decode_callsign(data: bytes) -> tuple:
        """Decode 7-byte AX.25 address field"""
        if len(data) < 7:
            return "??????", 0, False

        chars = []
        for i in range(6):
            c = (data[i] >> 1) & 0x7F
            if c != 0x20:  # Space
                chars.append(chr(c))

        callsign = ''.join(chars)
        ssid = (data[6] >> 1) & 0x0F
        is_last = bool(data[6] & 0x01)

        if ssid > 0:
            callsign = f"{callsign}-{ssid}"

        return callsign, ssid, is_last

    @staticmethod
    def decode_frame_type(control: int) -> tuple:
        """Decode control field to frame type"""
        # I-frame: bit 0 = 0
        if (control & 0x01) == 0:
            ns = (control >> 1) & 0x07
            nr = (control >> 5) & 0x07
            pf = bool(control & 0x10)
            return FrameType.I, ns, nr, pf

        # S-frame: bits 0-1 = 01
        if (control & 0x03) == 0x01:
            nr = (control >> 5) & 0x07
            pf = bool(control & 0x10)
            s_type = (control >> 2) & 0x03
            if s_type == 0:
                return FrameType.RR, None, nr, pf
            elif s_type == 1:
                return FrameType.RNR, None, nr, pf
            elif s_type == 2:
                return FrameType.REJ, None, nr, pf
            return FrameType.UNKNOWN, None, nr, pf

        # U-frame: bits 0-1 = 11
        pf = bool(control & 0x10)
        u_type = control & 0xEF  # Mask out P/F bit
        if u_type == 0x03:
            return FrameType.UI, None, None, pf
        elif u_type == 0x2F:
            return FrameType.SABM, None, None, pf
        elif u_type == 0x6F:
            return FrameType.SABME, None, None, pf
        elif u_type == 0x63:
            return FrameType.UA, None, None, pf
        elif u_type == 0x0F:
            return FrameType.DM, None, None, pf
        elif u_type == 0x43:
            return FrameType.DISC, None, None, pf
        elif u_type == 0x87:
            return FrameType.FRMR, None, None, pf
        elif u_type == 0xAF:
            return FrameType.XID, None, None, pf
        elif u_type == 0xE3:
            return FrameType.TEST, None, None, pf

        return FrameType.UNKNOWN, None, None, pf

    @classmethod
    def decode(cls, kiss_frame: bytes, direction: str) -> Optional[DecodedFrame]:
        """Decode a KISS frame to AX.25"""
        if len(kiss_frame) < 1:
            return None

        # Skip KISS command byte
        cmd = kiss_frame[0]
        if (cmd & 0x0F) != 0:  # Not a data frame
            return None

        ax25_data = kiss_frame[1:]
        if len(ax25_data) < 15:  # Minimum: dest(7) + src(7) + ctrl(1)
            return None

        try:
            # Decode destination
            dest, _, _ = cls.decode_callsign(ax25_data[0:7])

            # Decode source
            src, _, is_last = cls.decode_callsign(ax25_data[7:14])

            # Decode via path
            via_path = []
            offset = 14
            while not is_last and offset + 7 <= len(ax25_data):
                via, _, is_last = cls.decode_callsign(ax25_data[offset:offset+7])
                via_path.append(via)
                offset += 7

            if offset >= len(ax25_data):
                return None

            # Control field
            control = ax25_data[offset]
            frame_type, ns, nr, pf = cls.decode_frame_type(control)
            offset += 1

            # PID (for I and UI frames)
            pid = None
            if frame_type in (FrameType.I, FrameType.UI) and offset < len(ax25_data):
                pid = ax25_data[offset]
                offset += 1

            # Payload
            payload = ax25_data[offset:] if offset < len(ax25_data) else b''

            # Check for AXDP
            is_axdp = payload.startswith(cls.AXDP_MAGIC)

            return DecodedFrame(
                source=src,
                destination=dest,
                via_path=via_path,
                frame_type=frame_type,
                control=control,
                pid=pid,
                payload=payload,
                raw=kiss_frame,
                timestamp=datetime.now(),
                direction=direction,
                ns=ns,
                nr=nr,
                poll_final=pf,
                is_axdp=is_axdp
            )
        except Exception:
            return None


class TrafficMonitor:
    """Monitors KISS traffic on relay ports"""

    def __init__(self, relay_host: str = "localhost", port_a: int = 8001, port_b: int = 8002):
        self.relay_host = relay_host
        self.port_a = port_a
        self.port_b = port_b

        self.stats_a = StationStats()
        self.stats_b = StationStats()
        self.frames: deque = deque(maxlen=100)
        self.start_time = datetime.now()

        self.running = False
        self.lock = threading.Lock()

        # Rate tracking
        self.frame_times: deque = deque(maxlen=100)

    def get_frames_per_second(self) -> float:
        """Calculate recent frames per second"""
        now = time.time()
        with self.lock:
            # Remove old entries
            while self.frame_times and now - self.frame_times[0] > 5:
                self.frame_times.popleft()
            if len(self.frame_times) < 2:
                return 0.0
            duration = self.frame_times[-1] - self.frame_times[0]
            if duration < 0.1:
                return 0.0
            return len(self.frame_times) / duration

    def add_frame(self, frame: DecodedFrame):
        """Add a decoded frame to history"""
        with self.lock:
            self.frames.append(frame)
            self.frame_times.append(time.time())

            # Update stats based on direction
            if frame.direction == "A→B":
                self.stats_a.frames_sent += 1
                self.stats_a.bytes_sent += len(frame.raw)
                self.stats_b.frames_received += 1
                self.stats_b.bytes_received += len(frame.raw)
                self.stats_a.last_activity = frame.timestamp
            else:
                self.stats_b.frames_sent += 1
                self.stats_b.bytes_sent += len(frame.raw)
                self.stats_a.frames_received += 1
                self.stats_a.bytes_received += len(frame.raw)
                self.stats_b.last_activity = frame.timestamp

            # Frame type stats
            stats = self.stats_a if frame.direction == "A→B" else self.stats_b
            if frame.frame_type == FrameType.I:
                stats.i_frames += 1
            elif frame.frame_type in (FrameType.RR, FrameType.RNR, FrameType.REJ):
                stats.s_frames += 1
            else:
                stats.u_frames += 1

            if frame.is_axdp:
                stats.axdp_frames += 1

    def monitor_port(self, port: int, direction: str):
        """Monitor a single port for traffic"""
        decoder = KISSDecoder()
        reconnect_delay = 1

        while self.running:
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(1.0)
                sock.connect((self.relay_host, port))

                # Mark connected
                with self.lock:
                    if direction == "A→B":
                        self.stats_a.connected = True
                    else:
                        self.stats_b.connected = True

                reconnect_delay = 1
                sock.settimeout(0.1)

                while self.running:
                    try:
                        data = sock.recv(4096)
                        if not data:
                            break
                        frames = decoder.feed(data)
                        for kiss_frame in frames:
                            decoded = AX25Decoder.decode(kiss_frame, direction)
                            if decoded:
                                self.add_frame(decoded)
                    except socket.timeout:
                        continue
                    except Exception:
                        break

            except Exception:
                with self.lock:
                    if direction == "A→B":
                        self.stats_a.connected = False
                    else:
                        self.stats_b.connected = False

            time.sleep(reconnect_delay)
            reconnect_delay = min(reconnect_delay * 2, 10)

    def start(self):
        """Start monitoring"""
        self.running = True
        threading.Thread(target=self.monitor_port, args=(self.port_a, "A→B"), daemon=True).start()
        threading.Thread(target=self.monitor_port, args=(self.port_b, "B→A"), daemon=True).start()

    def stop(self):
        """Stop monitoring"""
        self.running = False


def format_frame_type(frame: DecodedFrame) -> Text:
    """Format frame type with color"""
    colors = {
        FrameType.I: "green",
        FrameType.UI: "blue",
        FrameType.RR: "cyan",
        FrameType.RNR: "yellow",
        FrameType.REJ: "red",
        FrameType.SABM: "magenta",
        FrameType.SABME: "magenta",
        FrameType.UA: "green",
        FrameType.DM: "red",
        FrameType.DISC: "red",
        FrameType.FRMR: "red bold",
    }
    color = colors.get(frame.frame_type, "white")
    text = frame.frame_type.value

    if frame.frame_type == FrameType.I:
        text = f"I(S={frame.ns},R={frame.nr})"
    elif frame.frame_type in (FrameType.RR, FrameType.RNR, FrameType.REJ):
        text = f"{frame.frame_type.value}(R={frame.nr})"

    if frame.poll_final:
        text += " P/F"

    return Text(text, style=color)


def format_payload_preview(payload: bytes, max_len: int = 30) -> str:
    """Format payload preview"""
    if not payload:
        return ""

    # Check for AXDP
    if payload.startswith(b'AXT1'):
        return f"[AXDP] {len(payload)} bytes"

    # Try to decode as text
    try:
        text = payload.decode('ascii', errors='replace')
        text = ''.join(c if c.isprintable() else '.' for c in text)
        if len(text) > max_len:
            text = text[:max_len] + "..."
        return text
    except Exception:
        return f"{len(payload)} bytes"


def create_dashboard(monitor: TrafficMonitor) -> Layout:
    """Create the monitoring dashboard layout"""
    layout = Layout()

    layout.split_column(
        Layout(name="header", size=3),
        Layout(name="stats", size=10),
        Layout(name="frames"),
        Layout(name="footer", size=3)
    )

    layout["stats"].split_row(
        Layout(name="station_a"),
        Layout(name="station_b"),
        Layout(name="performance")
    )

    return layout


def update_dashboard(layout: Layout, monitor: TrafficMonitor):
    """Update dashboard with current data"""
    # Header
    header = Table.grid(expand=True)
    header.add_column(justify="center")
    header.add_row(Text("AXTerm KISS Traffic Monitor", style="bold cyan"))
    layout["header"].update(Panel(header, box=box.ROUNDED))

    # Station A stats
    stats_a = monitor.stats_a
    a_table = Table(show_header=False, box=None, padding=(0, 1))
    a_table.add_column(style="dim")
    a_table.add_column()
    status_a = Text("● Connected", style="green") if stats_a.connected else Text("○ Disconnected", style="red")
    a_table.add_row("Status:", status_a)
    a_table.add_row("Sent:", f"{stats_a.frames_sent} frames ({stats_a.bytes_sent:,} bytes)")
    a_table.add_row("Received:", f"{stats_a.frames_received} frames ({stats_a.bytes_received:,} bytes)")
    a_table.add_row("I/S/U:", f"{stats_a.i_frames} / {stats_a.s_frames} / {stats_a.u_frames}")
    a_table.add_row("AXDP:", f"{stats_a.axdp_frames} frames")
    layout["station_a"].update(Panel(a_table, title="[cyan]Station A (TEST-1)[/cyan]", border_style="cyan"))

    # Station B stats
    stats_b = monitor.stats_b
    b_table = Table(show_header=False, box=None, padding=(0, 1))
    b_table.add_column(style="dim")
    b_table.add_column()
    status_b = Text("● Connected", style="green") if stats_b.connected else Text("○ Disconnected", style="red")
    b_table.add_row("Status:", status_b)
    b_table.add_row("Sent:", f"{stats_b.frames_sent} frames ({stats_b.bytes_sent:,} bytes)")
    b_table.add_row("Received:", f"{stats_b.frames_received} frames ({stats_b.bytes_received:,} bytes)")
    b_table.add_row("I/S/U:", f"{stats_b.i_frames} / {stats_b.s_frames} / {stats_b.u_frames}")
    b_table.add_row("AXDP:", f"{stats_b.axdp_frames} frames")
    layout["station_b"].update(Panel(b_table, title="[magenta]Station B (TEST-2)[/magenta]", border_style="magenta"))

    # Performance metrics
    uptime = datetime.now() - monitor.start_time
    fps = monitor.get_frames_per_second()
    total_frames = stats_a.frames_sent + stats_b.frames_sent
    total_bytes = stats_a.bytes_sent + stats_b.bytes_sent

    perf_table = Table(show_header=False, box=None, padding=(0, 1))
    perf_table.add_column(style="dim")
    perf_table.add_column()
    perf_table.add_row("Uptime:", str(uptime).split('.')[0])
    perf_table.add_row("Rate:", f"{fps:.1f} frames/sec")
    perf_table.add_row("Total:", f"{total_frames} frames")
    perf_table.add_row("Bytes:", f"{total_bytes:,}")
    layout["performance"].update(Panel(perf_table, title="[yellow]Performance[/yellow]", border_style="yellow"))

    # Frame table
    frame_table = Table(box=box.SIMPLE, expand=True)
    frame_table.add_column("Time", style="dim", width=12)
    frame_table.add_column("Dir", width=5)
    frame_table.add_column("From", width=10)
    frame_table.add_column("To", width=10)
    frame_table.add_column("Type", width=15)
    frame_table.add_column("Info")

    with monitor.lock:
        frames_list = list(monitor.frames)

    for frame in reversed(frames_list[-20:]):  # Last 20 frames
        dir_style = "cyan" if frame.direction == "A→B" else "magenta"
        dir_text = Text(frame.direction, style=dir_style)

        info = format_payload_preview(frame.payload)
        if frame.via_path:
            via = " via " + ",".join(frame.via_path)
            info = via + " " + info if info else via

        frame_table.add_row(
            frame.timestamp.strftime("%H:%M:%S.%f")[:12],
            dir_text,
            frame.source,
            frame.destination,
            format_frame_type(frame),
            info
        )

    layout["frames"].update(Panel(frame_table, title="Recent Frames", border_style="white"))

    # Footer
    footer = Text("Press Ctrl+C to exit", style="dim", justify="center")
    layout["footer"].update(Panel(footer, box=box.ROUNDED))


def main():
    console = Console()

    console.print("\n[cyan]Starting AXTerm KISS Traffic Monitor...[/cyan]\n")

    monitor = TrafficMonitor()
    monitor.start()

    layout = create_dashboard(monitor)

    try:
        # Use vertical_overflow="visible" to reduce blinking
        with Live(layout, console=console, refresh_per_second=4, vertical_overflow="visible") as live:
            while True:
                update_dashboard(layout, monitor)
                time.sleep(0.25)
    except KeyboardInterrupt:
        pass
    finally:
        monitor.stop()
        console.print("\n[yellow]Monitor stopped.[/yellow]")


if __name__ == "__main__":
    main()
