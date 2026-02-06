#!/usr/bin/env python3
"""
KISS Frame Relay for AXTerm Testing

This relay simulates an RF link between two KISS TCP ports:
- Port 8001: Station A
- Port 8002: Station B

Frames received on one port are forwarded to all clients on the other port,
simulating broadcast RF where all stations hear each other.

Features:
- Multiple clients per port
- KISS frame parsing and forwarding
- Optional delay to simulate RF latency
- Logging for debugging
"""

import asyncio
import logging
from dataclasses import dataclass
from typing import Dict, Set
import time

# Configuration
PORT_A = 8001  # Station A
PORT_B = 8002  # Station B
RF_DELAY_MS = 50  # Simulated RF propagation delay
LOG_FRAMES = True  # Log frame activity

# KISS constants
FEND = 0xC0
FESC = 0xDB
TFEND = 0xDC
TFESC = 0xDD

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)
logger = logging.getLogger(__name__)


@dataclass
class Client:
    """A connected KISS client"""
    writer: asyncio.StreamWriter
    port: int
    addr: str
    id: int

    def __hash__(self):
        return hash(self.id)

    def __eq__(self, other):
        if isinstance(other, Client):
            return self.id == other.id
        return False


class KISSRelay:
    """Bidirectional KISS frame relay between two ports"""

    def __init__(self):
        self.clients: Dict[int, Set[Client]] = {PORT_A: set(), PORT_B: set()}
        self.client_counter = 0
        self.frame_counter = 0
        self.lock = asyncio.Lock()

    def get_peer_port(self, port: int) -> int:
        """Get the port that should receive relayed frames"""
        return PORT_B if port == PORT_A else PORT_A

    async def add_client(self, writer: asyncio.StreamWriter, port: int, addr: str) -> Client:
        """Register a new client connection"""
        async with self.lock:
            self.client_counter += 1
            client = Client(writer=writer, port=port, addr=addr, id=self.client_counter)
            self.clients[port].add(client)
            logger.info(f"Client {client.id} connected on port {port} from {addr}")
            logger.info(f"Active clients: Port A={len(self.clients[PORT_A])}, Port B={len(self.clients[PORT_B])}")
            return client

    async def remove_client(self, client: Client):
        """Unregister a client connection"""
        async with self.lock:
            self.clients[client.port].discard(client)
            logger.info(f"Client {client.id} disconnected from port {client.port}")
            logger.info(f"Active clients: Port A={len(self.clients[PORT_A])}, Port B={len(self.clients[PORT_B])}")

    async def relay_frame(self, frame: bytes, from_port: int, from_client: Client):
        """Relay a KISS frame to all clients on the peer port"""
        to_port = self.get_peer_port(from_port)

        # Simulated RF delay
        if RF_DELAY_MS > 0:
            await asyncio.sleep(RF_DELAY_MS / 1000.0)

        async with self.lock:
            self.frame_counter += 1
            frame_id = self.frame_counter
            recipients = list(self.clients[to_port])

        if LOG_FRAMES:
            # Extract payload info for logging
            payload_len = len(frame) - 3 if len(frame) > 3 else 0  # Subtract FEND + cmd + FEND
            logger.info(f"Frame #{frame_id}: {from_port}->{to_port} ({payload_len} bytes) to {len(recipients)} client(s)")

        # Send to all clients on peer port
        for client in recipients:
            try:
                client.writer.write(frame)
                await client.writer.drain()
            except Exception as e:
                logger.warning(f"Failed to send to client {client.id}: {e}")

    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, port: int):
        """Handle a client connection"""
        addr = writer.get_extra_info('peername')
        addr_str = f"{addr[0]}:{addr[1]}" if addr else "unknown"

        client = await self.add_client(writer, port, addr_str)

        try:
            buffer = bytearray()
            in_frame = False

            while True:
                data = await reader.read(1024)
                if not data:
                    break

                # Parse KISS frames from stream
                for byte in data:
                    if byte == FEND:
                        if in_frame and len(buffer) > 0:
                            # Complete frame - relay it
                            frame = bytes([FEND]) + bytes(buffer) + bytes([FEND])
                            asyncio.create_task(self.relay_frame(frame, port, client))
                        buffer.clear()
                        in_frame = True
                    elif in_frame:
                        buffer.append(byte)

        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Client {client.id} error: {e}")
        finally:
            await self.remove_client(client)
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass


async def main():
    """Start the relay servers"""
    relay = KISSRelay()

    async def handle_port_a(reader, writer):
        await relay.handle_client(reader, writer, PORT_A)

    async def handle_port_b(reader, writer):
        await relay.handle_client(reader, writer, PORT_B)

    server_a = await asyncio.start_server(handle_port_a, '0.0.0.0', PORT_A)
    server_b = await asyncio.start_server(handle_port_b, '0.0.0.0', PORT_B)

    logger.info("=" * 60)
    logger.info("AXTerm KISS Relay Started")
    logger.info("=" * 60)
    logger.info(f"Station A: port {PORT_A}")
    logger.info(f"Station B: port {PORT_B}")
    logger.info(f"RF delay: {RF_DELAY_MS}ms")
    logger.info("=" * 60)
    logger.info("Frames sent to one port will be relayed to the other")
    logger.info("Connect AXTerm to localhost:8001 or localhost:8002")
    logger.info("=" * 60)

    async with server_a, server_b:
        await asyncio.gather(
            server_a.serve_forever(),
            server_b.serve_forever()
        )


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Relay stopped")
