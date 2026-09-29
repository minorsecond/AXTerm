#!/usr/bin/env python3
"""
Quick test: Open TNC4 serial port WITHOUT O_EXLOCK, send battery poll,
and print any bytes received. This verifies the serial read path works.
"""
import os, sys, termios, time, select, fcntl

DEVICE = "/dev/cu.TNC4Mobilinkd"
BAUD = 115200  # B115200

# KISS frames
KISS_FEND = 0xC0
BATTERY_POLL = bytes([KISS_FEND, 0x06, 0x06, KISS_FEND])
RESET_DEMOD  = bytes([KISS_FEND, 0x06, 0x0B, KISS_FEND])

def main():
    print(f"Opening {DEVICE} (NO O_EXLOCK)...")

    # Open WITHOUT O_EXLOCK - just O_RDWR | O_NOCTTY | O_NONBLOCK
    fd = os.open(DEVICE, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    print(f"  fd={fd}, opened successfully")

    # Configure: raw mode, 115200, 8N1, no flow control
    attrs = termios.tcgetattr(fd)
    # Raw mode
    attrs[0] = termios.IGNBRK  # iflag
    attrs[1] = 0                # oflag
    attrs[2] = (termios.CS8 | termios.CLOCAL | termios.CREAD)  # cflag
    attrs[3] = 0                # lflag
    attrs[4] = termios.B115200  # ispeed
    attrs[5] = termios.B115200  # ospeed
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)

    # Assert DTR/RTS
    TIOCMBIS = 0x8004746c
    import struct, ctypes
    bits = struct.pack('i', 0x002 | 0x004)  # TIOCM_DTR | TIOCM_RTS
    fcntl.ioctl(fd, TIOCMBIS, bits)
    print("  DTR/RTS asserted")

    time.sleep(1.0)  # Let TNC initialize

    # Send reset to ensure demodulator is running
    print(f"  Sending RESET: {RESET_DEMOD.hex(' ')}")
    os.write(fd, RESET_DEMOD)
    time.sleep(0.5)

    # Send battery poll
    print(f"  Sending BATTERY_POLL: {BATTERY_POLL.hex(' ')}")
    os.write(fd, BATTERY_POLL)

    # Wait for response
    print("\nWaiting for data (10 seconds)...")
    start = time.time()
    total_rx = 0

    while time.time() - start < 10:
        ready, _, _ = select.select([fd], [], [], 0.5)
        if ready:
            try:
                data = os.read(fd, 4096)
                if data:
                    total_rx += len(data)
                    hex_str = ' '.join(f'{b:02X}' for b in data)
                    print(f"  RX ({len(data)} bytes): {hex_str}")
                else:
                    print("  RX: EOF (0 bytes)")
                    break
            except OSError as e:
                if e.errno == 35:  # EAGAIN
                    pass
                else:
                    print(f"  Read error: {e}")
                    break
        else:
            elapsed = time.time() - start
            if int(elapsed) % 3 == 0 and int(elapsed) > 0:
                # Resend battery poll every ~3s
                os.write(fd, BATTERY_POLL)

    print(f"\nTotal RX bytes: {total_rx}")
    if total_rx == 0:
        print("WARNING: No data received from TNC4!")
        print("  - Check USB cable connection")
        print("  - Try unplugging and replugging the TNC4")
    else:
        print("SUCCESS: TNC4 is responding!")

    os.close(fd)

if __name__ == "__main__":
    main()
