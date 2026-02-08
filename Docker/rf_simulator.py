#!/usr/bin/env python3
"""
RF Channel Simulator for AXTerm Integration Testing

This simulator models a shared RF channel that multiple stations access.
It handles:
- KISS frame parsing and forwarding
- Channel access simulation (carrier sense, collision detection)
- Configurable propagation delay
- Configurable bit error rate for stress testing
- Frame logging and analysis

Unlike a simple relay, this simulates actual RF behavior:
- All stations hear all frames (broadcast medium)
- Frames can collide during simultaneous transmission
- Realistic timing for channel access

Ports:
- 8001: Station A (e.g., TEST-1)
- 8002: Station B (e.g., TEST-2)
- 8003: Station C (optional, for multi-station tests)
- 8004: Station D (optional)
"""

import asyncio
import logging
import random
import struct
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Dict, List, Set, Optional
import hashlib

# Configuration
STATION_PORTS = [8001, 8002, 8003, 8004]
ACTIVE_PORTS = [8001, 8002]  # Default: two stations

# RF Channel Parameters
PROPAGATION_DELAY_MS = 10  # Speed of light delay (simulated)
TX_DELAY_MS = 100  # TXDelay (transmitter keying time)
SLOT_TIME_MS = 10  # p-persistence slot time
PERSISTENCE = 63  # p-persistence value (0-255, 63 = ~25% chance per slot)
BIT_ERROR_RATE = 0.0  # 0.0 = perfect, 0.001 = 0.1% BER

# KISS Protocol
FEND = 0xC0
FESC = 0xDB
TFEND = 0xDC
TFESC = 0xDD

# AX.25 Frame Types
class FrameType(Enum):
    I_FRAME = "I"
    S_FRAME = "S"
    U_FRAME = "U"
    UNKNOWN = "?"

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s.%(msecs)03d [%(levelname)s] %(message)s',
    datefmt='%H:%M:%S'
)
logger = logging.getLogger(__name__)


@dataclass
class AX25Address:
    """Decoded AX.25 address"""
    callsign: str
    ssid: int

    def __str__(self):
        if self.ssid == 0:
            return self.callsign
        return f"{self.callsign}-{self.ssid}"


@dataclass
class AX25Frame:
    """Decoded AX.25 frame for logging and analysis"""
    raw: bytes
    dest: Optional[AX25Address] = None
    source: Optional[AX25Address] = None
    via: List[AX25Address] = field(default_factory=list)
    control: int = 0
    frame_type: FrameType = FrameType.UNKNOWN
    ns: int = 0  # N(S) for I-frames
    nr: int = 0  # N(R) for I/S-frames
    pf: bool = False  # Poll/Final bit
    pid: int = 0
    info: bytes = b""

    def __str__(self):
        via_str = f" via {','.join(str(v) for v in self.via)}" if self.via else ""
        type_detail = ""
        if self.frame_type == FrameType.I_FRAME:
            type_detail = f" I N(S)={self.ns} N(R)={self.nr}"
        elif self.frame_type == FrameType.S_FRAME:
            s_types = {0: "RR", 1: "RNR", 2: "REJ", 3: "SREJ"}
            s_type = s_types.get((self.control >> 2) & 0x03, "S?")
            type_detail = f" {s_type} N(R)={self.nr}"
        elif self.frame_type == FrameType.U_FRAME:
            u_types = {
                0x2F: "SABM", 0x0F: "DM", 0x43: "DISC",
                0x63: "UA", 0x03: "UI", 0x87: "FRMR"
            }
            u_type = u_types.get(self.control & 0xEF, f"U({self.control:02X})")
            type_detail = f" {u_type}"
        pf_str = " P/F" if self.pf else ""
        return f"{self.source}->{self.dest}{via_str}{type_detail}{pf_str}"


def decode_ax25_address(data: bytes, offset: int) -> tuple[AX25Address, bool]:
    """Decode a 7-byte AX.25 address field"""
    if len(data) < offset + 7:
        return AX25Address("??????", 0), True

    # Callsign: 6 bytes, each shifted left by 1
    callsign = ""
    for i in range(6):
        char = (data[offset + i] >> 1) & 0x7F
        if char != 0x20:  # Not space
            callsign += chr(char)

    # SSID byte
    ssid_byte = data[offset + 6]
    ssid = (ssid_byte >> 1) & 0x0F
    is_last = bool(ssid_byte & 0x01)

    return AX25Address(callsign.strip(), ssid), is_last


def decode_ax25_frame(data: bytes) -> AX25Frame:
    """Decode an AX.25 frame for logging"""
    frame = AX25Frame(raw=data)

    if len(data) < 14:  # Minimum: dest(7) + src(7)
        return frame

    # Decode destination
    frame.dest, _ = decode_ax25_address(data, 0)

    # Decode source
    frame.source, is_last = decode_ax25_address(data, 7)

    # Decode via path (repeaters)
    offset = 14
    while not is_last and offset + 7 <= len(data):
        via_addr, is_last = decode_ax25_address(data, offset)
        frame.via.append(via_addr)
        offset += 7

    # Control field
    if offset < len(data):
        frame.control = data[offset]
        offset += 1

        # Determine frame type
        if (frame.control & 0x01) == 0:
            # I-frame
            frame.frame_type = FrameType.I_FRAME
            frame.ns = (frame.control >> 1) & 0x07
            frame.nr = (frame.control >> 5) & 0x07
            frame.pf = bool(frame.control & 0x10)
        elif (frame.control & 0x03) == 0x01:
            # S-frame
            frame.frame_type = FrameType.S_FRAME
            frame.nr = (frame.control >> 5) & 0x07
            frame.pf = bool(frame.control & 0x10)
        else:
            # U-frame
            frame.frame_type = FrameType.U_FRAME
            frame.pf = bool(frame.control & 0x10)

    # PID (for I and UI frames)
    if frame.frame_type == FrameType.I_FRAME or (frame.frame_type == FrameType.U_FRAME and (frame.control & 0xEF) == 0x03):
        if offset < len(data):
            frame.pid = data[offset]
            offset += 1

    # Info field
    if offset < len(data):
        frame.info = data[offset:]

    return frame


def kiss_unescape(data: bytes) -> bytes:
    """Unescape KISS frame data"""
    result = bytearray()
    i = 0
    while i < len(data):
        if data[i] == FESC:
            if i + 1 < len(data):
                if data[i + 1] == TFEND:
                    result.append(FEND)
                elif data[i + 1] == TFESC:
                    result.append(FESC)
                else:
                    result.append(data[i + 1])
                i += 2
            else:
                i += 1
        else:
            result.append(data[i])
            i += 1
    return bytes(result)


def apply_bit_errors(data: bytes, ber: float) -> bytes:
    """Apply random bit errors to simulate RF impairments"""
    if ber <= 0:
        return data

    result = bytearray(data)
    for i in range(len(result)):
        for bit in range(8):
            if random.random() < ber:
                result[i] ^= (1 << bit)
    return bytes(result)


@dataclass
class Station:
    """A connected station"""
    writer: asyncio.StreamWriter
    port: int
    addr: str
    id: int
    tx_count: int = 0
    rx_count: int = 0
    last_tx: float = 0

    def __hash__(self):
        return hash(self.id)

    def __eq__(self, other):
        if isinstance(other, Station):
            return self.id == other.id
        return False


class RFChannel:
    """
    Simulated RF channel with realistic behavior

    Models:
    - Broadcast medium (all stations hear all frames)
    - Channel busy detection
    - Collision detection
    - Propagation delay
    - Optional bit errors
    """

    def __init__(self, ber: float = BIT_ERROR_RATE):
        self.stations: Dict[int, Set[Station]] = {p: set() for p in STATION_PORTS}
        self.station_counter = 0
        self.frame_counter = 0
        self.lock = asyncio.Lock()
        self.channel_busy = False
        self.channel_busy_until = 0
        self.ber = ber
        self.collision_count = 0
        self.recent_frames: Dict[str, float] = {}  # hash -> timestamp for dupe detection

    async def add_station(self, writer: asyncio.StreamWriter, port: int, addr: str) -> Station:
        """Register a new station connection"""
        async with self.lock:
            self.station_counter += 1
            station = Station(writer=writer, port=port, addr=addr, id=self.station_counter)
            self.stations[port].add(station)
            logger.info(f"Station {station.id} connected on port {port} from {addr}")
            self._log_station_count()
            return station

    async def remove_station(self, station: Station):
        """Unregister a station"""
        async with self.lock:
            self.stations[station.port].discard(station)
            logger.info(f"Station {station.id} disconnected (TX:{station.tx_count} RX:{station.rx_count})")
            self._log_station_count()

    def _log_station_count(self):
        counts = [f"{p}:{len(self.stations[p])}" for p in ACTIVE_PORTS if self.stations[p]]
        logger.info(f"Active stations: {', '.join(counts) if counts else 'none'}")

    def _frame_hash(self, ax25_data: bytes) -> str:
        """Generate hash for duplicate detection"""
        return hashlib.md5(ax25_data).hexdigest()[:12]

    async def transmit(self, kiss_frame: bytes, from_station: Station):
        """
        Transmit a frame from a station onto the RF channel

        The frame will be received by all other stations (including
        stations on the same port for digipeater scenarios).
        """
        current_time = time.time()

        # Parse KISS frame to get AX.25 payload
        if len(kiss_frame) < 3:
            return

        # Extract KISS command and payload
        kiss_cmd = kiss_frame[0]  # Should be 0x00 for data
        ax25_data = kiss_unescape(kiss_frame[1:])

        if len(ax25_data) < 14:
            logger.warning(f"Station {from_station.id}: Frame too short ({len(ax25_data)} bytes)")
            return

        # Decode for logging
        frame = decode_ax25_frame(ax25_data)

        # Check for collision
        async with self.lock:
            if self.channel_busy and current_time < self.channel_busy_until:
                self.collision_count += 1
                logger.warning(f"COLLISION! Station {from_station.id} transmitted during busy channel")
                # In a real scenario, both frames would be corrupted
                # For testing, we'll still relay but log the collision

            # Mark channel as busy for frame duration
            # Approximate: 1200 baud = ~120 bytes/sec
            frame_duration_ms = (len(ax25_data) * 8 / 1200) * 1000 + TX_DELAY_MS
            self.channel_busy = True
            self.channel_busy_until = current_time + (frame_duration_ms / 1000)

            self.frame_counter += 1
            frame_id = self.frame_counter
            from_station.tx_count += 1

        # Check for duplicate (within 1 second window)
        frame_hash = self._frame_hash(ax25_data)
        is_dupe = False
        async with self.lock:
            if frame_hash in self.recent_frames:
                if current_time - self.recent_frames[frame_hash] < 1.0:
                    is_dupe = True
            self.recent_frames[frame_hash] = current_time
            # Clean old entries
            old_hashes = [h for h, t in self.recent_frames.items() if current_time - t > 5.0]
            for h in old_hashes:
                del self.recent_frames[h]

        # Log the transmission
        dupe_marker = " [DUPE]" if is_dupe else ""
        logger.info(f"[{frame_id:04d}] TX Station {from_station.id}: {frame}{dupe_marker}")
        if frame.info:
            # Log payload preview (first 40 bytes)
            info_preview = frame.info[:40].decode('utf-8', errors='replace')
            if len(frame.info) > 40:
                info_preview += "..."
            logger.debug(f"       Payload: {info_preview}")

        # Simulate propagation delay
        await asyncio.sleep(PROPAGATION_DELAY_MS / 1000)

        # Apply bit errors if configured
        if self.ber > 0:
            ax25_data = apply_bit_errors(ax25_data, self.ber)

        # Rebuild KISS frame with potentially corrupted data
        kiss_out = bytes([FEND, kiss_cmd]) + self._kiss_escape(ax25_data) + bytes([FEND])

        # Broadcast to all other stations
        async with self.lock:
            recipients = []
            for port, stations in self.stations.items():
                for station in stations:
                    if station != from_station:
                        recipients.append(station)

        for station in recipients:
            try:
                station.writer.write(kiss_out)
                await station.writer.drain()
                async with self.lock:
                    station.rx_count += 1
            except Exception as e:
                logger.warning(f"Failed to deliver to station {station.id}: {e}")

        logger.debug(f"[{frame_id:04d}] Delivered to {len(recipients)} station(s)")

    def _kiss_escape(self, data: bytes) -> bytes:
        """Escape special KISS bytes"""
        result = bytearray()
        for byte in data:
            if byte == FEND:
                result.extend([FESC, TFEND])
            elif byte == FESC:
                result.extend([FESC, TFESC])
            else:
                result.append(byte)
        return bytes(result)

    async def handle_station(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, port: int):
        """Handle a station connection"""
        addr = writer.get_extra_info('peername')
        addr_str = f"{addr[0]}:{addr[1]}" if addr else "unknown"

        station = await self.add_station(writer, port, addr_str)

        try:
            buffer = bytearray()
            in_frame = False

            while True:
                data = await reader.read(4096)
                if not data:
                    break

                # Parse KISS frames
                for byte in data:
                    if byte == FEND:
                        if in_frame and len(buffer) > 0:
                            # Complete frame
                            frame_data = bytes(buffer)
                            asyncio.create_task(self.transmit(frame_data, station))
                        buffer.clear()
                        in_frame = True
                    elif in_frame:
                        buffer.append(byte)

        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Station {station.id} error: {e}")
        finally:
            await self.remove_station(station)
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass


async def main():
    """Start the RF channel simulator"""
    channel = RFChannel(ber=BIT_ERROR_RATE)

    servers = []
    for port in ACTIVE_PORTS:
        async def make_handler(p):
            return lambda r, w: channel.handle_station(r, w, p)

        handler = await make_handler(port)
        server = await asyncio.start_server(handler, '0.0.0.0', port)
        servers.append(server)

    logger.info("=" * 70)
    logger.info("AXTerm RF Channel Simulator")
    logger.info("=" * 70)
    logger.info(f"Active ports: {ACTIVE_PORTS}")
    logger.info(f"Propagation delay: {PROPAGATION_DELAY_MS}ms")
    logger.info(f"TX delay: {TX_DELAY_MS}ms")
    logger.info(f"Bit error rate: {BIT_ERROR_RATE}")
    logger.info("=" * 70)
    logger.info("All frames are broadcast to all connected stations")
    logger.info("Connect AXTerm instances to separate ports for testing")
    logger.info("=" * 70)

    await asyncio.gather(*[s.serve_forever() for s in servers])


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Simulator stopped")
