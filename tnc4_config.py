#!/usr/bin/env python3
"""
tnc4_config.py — Dump or restore Mobilinkd TNC4 settings via USB serial.

Usage:
    ./tnc4_config.py dump                     # Dump current settings to stdout (JSON)
    ./tnc4_config.py dump -o settings.json    # Dump to file
    ./tnc4_config.py apply settings.json      # Apply settings from JSON file
    ./tnc4_config.py factory                  # Apply factory defaults (built-in)
    ./tnc4_config.py apply --dry-run file.json  # Show what would be sent

Options:
    -d, --device PATH    Serial device (auto-detects /dev/cu.usbmodem*)
    -o, --output PATH    Output file for dump mode
    --dry-run            Show commands without sending
    --no-save            Don't persist to EEPROM (changes lost on power cycle)
    --no-reset           Don't send RESET after applying
"""

import argparse
import fcntl
import glob
import json
import os
import struct
import sys
import termios
import time


# ── KISS framing ──────────────────────────────────────────────────────────

FEND = 0xC0
FESC = 0xDB
TFEND = 0xDC
TFESC = 0xDD

KISS_TYPE_DATA = 0x00
KISS_TYPE_TXDELAY = 0x01
KISS_TYPE_PERSIST = 0x02
KISS_TYPE_SLOTTIME = 0x03
KISS_TYPE_TXTAIL = 0x04
KISS_TYPE_DUPLEX = 0x05
KISS_TYPE_HARDWARE = 0x06


def kiss_frame(kiss_type: int, payload: bytes) -> bytes:
    """Build a KISS frame: FEND + type + SLIP-escaped payload + FEND."""
    out = bytearray([FEND, kiss_type])
    for b in payload:
        if b == FEND:
            out.extend([FESC, TFEND])
        elif b == FESC:
            out.extend([FESC, TFESC])
        else:
            out.append(b)
    out.append(FEND)
    return bytes(out)


def kiss_unescape(data: bytes) -> bytes:
    """SLIP-unescape a KISS payload."""
    out = bytearray()
    esc = False
    for b in data:
        if esc:
            if b == TFEND:
                out.append(FEND)
            elif b == TFESC:
                out.append(FESC)
            else:
                out.append(b)
            esc = False
        elif b == FESC:
            esc = True
        else:
            out.append(b)
    return bytes(out)


def extract_kiss_frames(raw: bytes) -> list:
    """Extract KISS frames from raw serial bytes. Returns [(type, payload), ...]."""
    frames = []
    i = 0
    while i < len(raw):
        if raw[i] == FEND:
            i += 1
            while i < len(raw) and raw[i] == FEND:
                i += 1
            if i >= len(raw):
                break
            # Collect until next FEND
            frame_bytes = bytearray()
            while i < len(raw) and raw[i] != FEND:
                frame_bytes.append(raw[i])
                i += 1
            if frame_bytes:
                unescaped = kiss_unescape(bytes(frame_bytes))
                if unescaped:
                    frames.append((unescaped[0], unescaped[1:]))
        else:
            i += 1
    return frames


# ── TNC4 hardware commands ───────────────────────────────────────────────

# SET commands (KISS type 0x06, payload = [cmd, value...])
HW_SET_OUTPUT_GAIN = 0x01
HW_SET_INPUT_GAIN = 0x02
HW_SET_SQUELCH = 0x03
HW_RESET = 0x0B
HW_SET_INPUT_TWIST = 0x18
HW_SET_OUTPUT_TWIST = 0x1A
HW_SAVE_EEPROM = 0x2A
HW_SET_USB_POWER_ON = 0x49
HW_SET_USB_POWER_OFF = 0x4B
HW_SET_PTT_CHANNEL = 0x4F
HW_SET_PASSALL = 0x51
HW_SET_RX_REV_POLARITY = 0x53
HW_SET_TX_REV_POLARITY = 0x55
HW_GET_ALL_VALUES = 0x7F

# GET command bytes (for parsing responses)
HW_CMD_NAMES = {
    0x01: "SET_OUTPUT_GAIN", 0x02: "SET_INPUT_GAIN",
    0x03: "SET_SQUELCH_LEVEL", 0x04: "POLL_INPUT_LEVEL",
    0x06: "GET_BATTERY_LEVEL", 0x0B: "RESET",
    0x0C: "GET_OUTPUT_GAIN", 0x0D: "GET_INPUT_GAIN",
    0x10: "SET_VERBOSITY", 0x11: "GET_VERBOSITY",
    0x18: "SET_INPUT_TWIST", 0x19: "GET_INPUT_TWIST",
    0x1A: "SET_OUTPUT_TWIST", 0x1B: "GET_OUTPUT_TWIST",
    0x21: "GET_TXDELAY", 0x22: "GET_PERSIST",
    0x23: "GET_TIMESLOT", 0x24: "GET_TXTAIL",
    0x25: "GET_DUPLEX", 0x28: "GET_FIRMWARE_VERSION",
    0x29: "GET_HARDWARE_VERSION", 0x2A: "SAVE_EEPROM",
    0x2F: "GET_SERIAL_NUMBER", 0x30: "GET_MAC_ADDRESS",
    0x31: "GET_DATETIME", 0x33: "GET_ERROR_MSG",
    0x42: "GET_BT_NAME", 0x44: "GET_BT_PIN",
    0x46: "GET_BT_CONN_TRACK", 0x48: "GET_BT_MAJOR_CLASS",
    0x49: "SET_USB_POWER_ON", 0x4A: "GET_USB_POWER_ON",
    0x4B: "SET_USB_POWER_OFF", 0x4C: "GET_USB_POWER_OFF",
    0x4D: "SET_BT_POWER_OFF", 0x4E: "GET_BT_POWER_OFF",
    0x4F: "SET_PTT_CHANNEL", 0x50: "GET_PTT_CHANNEL",
    0x51: "SET_PASSALL", 0x52: "GET_PASSALL",
    0x53: "SET_RX_REV_POLARITY", 0x54: "GET_RX_REV_POLARITY",
    0x55: "SET_TX_REV_POLARITY", 0x56: "GET_TX_REV_POLARITY",
    0x77: "GET_MIN_OUTPUT_TWIST", 0x78: "GET_MAX_OUTPUT_TWIST",
    0x79: "GET_MIN_INPUT_TWIST", 0x7A: "GET_MAX_INPUT_TWIST",
    0x7B: "GET_API_VERSION", 0x7C: "GET_MIN_INPUT_GAIN",
    0x7D: "GET_MAX_INPUT_GAIN", 0x7E: "GET_CAPABILITIES",
    0x7F: "GET_ALL_VALUES",
    0x81: "EXT_GET_MODEM_TYPE", 0x82: "EXT_SET_MODEM_TYPE",
    0x83: "EXT_GET_MODEM_TYPES",
}

STRING_COMMANDS = {0x28, 0x29, 0x2F, 0x33, 0x42, 0x44}

# Factory defaults (from tnc4_factory_defaults.json)
FACTORY_DEFAULTS = {
    "GET_DUPLEX": 1,
    "GET_INPUT_GAIN": 0,
    "GET_INPUT_TWIST": 7,
    "GET_OUTPUT_GAIN": 11,
    "GET_OUTPUT_TWIST": 50,
    "GET_PASSALL": 0,
    "GET_PERSIST": 255,
    "GET_PTT_CHANNEL": 1,
    "GET_RX_REV_POLARITY": 0,
    "GET_TIMESLOT": 0,
    "GET_TX_REV_POLARITY": 0,
    "GET_TXDELAY": 30,
    "GET_TXTAIL": 1,
    "GET_USB_POWER_OFF": 0,
    "GET_USB_POWER_ON": 0,
}

# Map JSON setting names to (kiss_type, command/subcommand, description)
# Standard KISS params use their own type byte; HW commands use type 0x06
SETTING_MAP = {
    "GET_TXDELAY":          (KISS_TYPE_TXDELAY,   None, "TX Delay"),
    "GET_PERSIST":          (KISS_TYPE_PERSIST,    None, "Persistence"),
    "GET_TIMESLOT":         (KISS_TYPE_SLOTTIME,   None, "Slot Time"),
    "GET_TXTAIL":           (KISS_TYPE_TXTAIL,     None, "TX Tail"),
    "GET_DUPLEX":           (KISS_TYPE_DUPLEX,     None, "Duplex"),
    "GET_OUTPUT_GAIN":      (KISS_TYPE_HARDWARE, HW_SET_OUTPUT_GAIN,     "Output Gain"),
    "GET_INPUT_GAIN":       (KISS_TYPE_HARDWARE, HW_SET_INPUT_GAIN,      "Input Gain"),
    "GET_INPUT_TWIST":      (KISS_TYPE_HARDWARE, HW_SET_INPUT_TWIST,     "Input Twist"),
    "GET_OUTPUT_TWIST":     (KISS_TYPE_HARDWARE, HW_SET_OUTPUT_TWIST,    "Output Twist"),
    "GET_PASSALL":          (KISS_TYPE_HARDWARE, HW_SET_PASSALL,         "Passall"),
    "GET_PTT_CHANNEL":      (KISS_TYPE_HARDWARE, HW_SET_PTT_CHANNEL,    "PTT Channel"),
    "GET_RX_REV_POLARITY":  (KISS_TYPE_HARDWARE, HW_SET_RX_REV_POLARITY, "RX Reverse Polarity"),
    "GET_TX_REV_POLARITY":  (KISS_TYPE_HARDWARE, HW_SET_TX_REV_POLARITY, "TX Reverse Polarity"),
    "GET_USB_POWER_ON":     (KISS_TYPE_HARDWARE, HW_SET_USB_POWER_ON,   "USB Power On"),
    "GET_USB_POWER_OFF":    (KISS_TYPE_HARDWARE, HW_SET_USB_POWER_OFF,  "USB Power Off"),
}


# ── Serial port ──────────────────────────────────────────────────────────

TIOCMBIS = 0x8004746C   # macOS ioctl to set modem bits
TIOCM_DTR = 0x002
TIOCM_RTS = 0x004


def find_device() -> str | None:
    """Auto-detect TNC4 USB serial device."""
    candidates = sorted(glob.glob("/dev/cu.usbmodem*"))
    return candidates[0] if candidates else None


def open_serial(path: str) -> int:
    """Open and configure a serial port. Returns file descriptor."""
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)

    attrs = termios.tcgetattr(fd)
    # cfmakeraw equivalent
    attrs[0] = 0   # iflag
    attrs[1] = 0   # oflag
    attrs[2] = termios.CS8 | termios.CLOCAL | termios.CREAD  # cflag
    attrs[3] = 0   # lflag
    attrs[4] = termios.B115200  # ispeed
    attrs[5] = termios.B115200  # ospeed
    # cc: VMIN=0, VTIME=0 for non-blocking
    cc = list(attrs[6])
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    attrs[6] = cc
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)

    # Assert DTR + RTS
    bits = struct.pack("i", TIOCM_DTR | TIOCM_RTS)
    fcntl.ioctl(fd, TIOCMBIS, bits)

    return fd


def read_all(fd: int) -> bytes:
    """Read all available data from a non-blocking fd."""
    chunks = []
    while True:
        try:
            data = os.read(fd, 4096)
            if not data:
                break
            chunks.append(data)
        except BlockingIOError:
            break
    return b"".join(chunks)


def read_until_quiet(fd: int, timeout: float = 5.0, quiet: float = 0.5) -> bytes:
    """Read until no data arrives for `quiet` seconds, or `timeout` expires."""
    result = bytearray()
    deadline = time.time() + timeout
    last_data = time.time()
    while time.time() < deadline:
        chunk = read_all(fd)
        if chunk:
            result.extend(chunk)
            last_data = time.time()
        elif time.time() - last_data > quiet:
            break
        time.sleep(0.05)
    return bytes(result)


def write_frame(fd: int, frame: bytes):
    """Write a complete KISS frame to the serial port."""
    os.write(fd, frame)


# ── Commands ─────────────────────────────────────────────────────────────

def cmd_dump(fd: int) -> dict:
    """Send GET_ALL_VALUES and parse the responses into a dict."""
    # Drain stale data
    read_all(fd)

    # Request all settings
    write_frame(fd, kiss_frame(KISS_TYPE_HARDWARE, bytes([HW_GET_ALL_VALUES])))
    raw = read_until_quiet(fd, timeout=5.0, quiet=1.0)

    frames = extract_kiss_frames(raw)
    settings = {}

    for kiss_type, payload in frames:
        if kiss_type == KISS_TYPE_HARDWARE and payload:
            cmd = payload[0]
            data = payload[1:]
            name = HW_CMD_NAMES.get(cmd, f"UNKNOWN_0x{cmd:02X}")

            if cmd in STRING_COMMANDS:
                val = data.decode("utf-8", errors="replace").strip("\x00\r\n")
                settings[name] = val
            elif len(data) == 1:
                settings[name] = data[0]
            elif len(data) == 2:
                settings[name] = (data[0] << 8) | data[1]
            elif len(data) == 6 and cmd == 0x30:  # MAC
                settings[name] = ":".join(f"{b:02X}" for b in data)
            elif len(data) == 7 and cmd == 0x31:  # Datetime
                settings[name] = "-".join(f"{b:02X}" for b in data)
            else:
                settings[name] = list(data)

    return settings


def build_set_commands(settings: dict) -> list:
    """Build a list of (description, kiss_frame_bytes) from a settings dict."""
    commands = []
    for key, value in sorted(settings.items()):
        if key not in SETTING_MAP:
            continue
        if not isinstance(value, int):
            continue

        kiss_type, hw_cmd, desc = SETTING_MAP[key]
        val = value & 0xFF

        if kiss_type == KISS_TYPE_HARDWARE:
            frame = kiss_frame(KISS_TYPE_HARDWARE, bytes([hw_cmd, val]))
        else:
            # Standard KISS param (type is the command itself)
            frame = kiss_frame(kiss_type, bytes([val]))

        commands.append((f"{desc} = {value}", frame))

    return commands


def cmd_apply(fd: int, settings: dict, dry_run: bool = False,
              save_eeprom: bool = True, reset: bool = True):
    """Apply settings to the TNC4."""
    commands = build_set_commands(settings)

    if not commands:
        print("No settable parameters found in input.")
        return

    print(f"Applying {len(commands)} settings:\n")
    for desc, frame in commands:
        hex_str = " ".join(f"{b:02X}" for b in frame)
        print(f"  {desc:30s}  [{hex_str}]")

    if dry_run:
        print("\n(dry run — nothing sent)")
        return

    # Drain stale data
    read_all(fd)
    time.sleep(0.5)

    # Send each command with a small delay
    for desc, frame in commands:
        write_frame(fd, frame)
        time.sleep(0.1)

    print(f"\nSent {len(commands)} commands.")

    if save_eeprom:
        print("Saving to EEPROM...")
        time.sleep(0.5)
        write_frame(fd, kiss_frame(KISS_TYPE_HARDWARE, bytes([HW_SAVE_EEPROM])))
        time.sleep(1.0)
        print("EEPROM saved.")

    if reset:
        print("Sending RESET (demodulator restart)...")
        time.sleep(0.5)
        write_frame(fd, kiss_frame(KISS_TYPE_HARDWARE, bytes([HW_RESET])))
        time.sleep(3.0)
        # Drain any post-reset data
        post = read_all(fd)
        if post:
            print(f"  (drained {len(post)} post-reset bytes)")
        print("RESET complete.")


# ── Main ─────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Dump or restore Mobilinkd TNC4 settings via USB serial.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s dump                          # Print current settings as JSON
  %(prog)s dump -o backup.json           # Save current settings to file
  %(prog)s apply backup.json             # Restore settings from file
  %(prog)s factory                       # Reset to factory defaults
  %(prog)s apply --dry-run backup.json   # Preview without sending
        """,
    )
    parser.add_argument(
        "-d", "--device", help="Serial device path (auto-detects /dev/cu.usbmodem*)"
    )

    sub = parser.add_subparsers(dest="command", required=True)

    # dump
    dump_p = sub.add_parser("dump", help="Dump current TNC4 settings")
    dump_p.add_argument("-o", "--output", help="Write JSON to file instead of stdout")

    # apply
    apply_p = sub.add_parser("apply", help="Apply settings from a JSON file")
    apply_p.add_argument("file", help="JSON settings file")
    apply_p.add_argument("--dry-run", action="store_true", help="Show commands without sending")
    apply_p.add_argument("--no-save", action="store_true", help="Don't persist to EEPROM")
    apply_p.add_argument("--no-reset", action="store_true", help="Don't send RESET after applying")

    # factory
    factory_p = sub.add_parser("factory", help="Apply built-in factory defaults")
    factory_p.add_argument("--dry-run", action="store_true", help="Show commands without sending")
    factory_p.add_argument("--no-save", action="store_true", help="Don't persist to EEPROM")
    factory_p.add_argument("--no-reset", action="store_true", help="Don't send RESET after applying")

    args = parser.parse_args()

    # Find device
    device = args.device or find_device()
    if not device:
        print("No TNC4 found at /dev/cu.usbmodem*", file=sys.stderr)
        print("Use -d /dev/cu.YOURDEVICE to specify manually.", file=sys.stderr)
        sys.exit(1)

    is_dry_run = getattr(args, "dry_run", False)

    if not is_dry_run:
        if not os.path.exists(device):
            print(f"Device not found: {device}", file=sys.stderr)
            sys.exit(1)
        print(f"Using device: {device}")

    # Open serial (skip for dry-run with factory/apply)
    fd = None
    if not is_dry_run:
        try:
            fd = open_serial(device)
        except OSError as e:
            print(f"Failed to open {device}: {e}", file=sys.stderr)
            sys.exit(1)
        print("Serial: 115200 8N1, DTR+RTS")
        time.sleep(1.0)  # Stabilization

    try:
        if args.command == "dump":
            settings = cmd_dump(fd)
            output = json.dumps(settings, indent=2, sort_keys=True)
            if args.output:
                with open(args.output, "w") as f:
                    f.write(output + "\n")
                print(f"\nSaved {len(settings)} settings to {args.output}")
            else:
                print(output)

        elif args.command == "apply":
            with open(args.file) as f:
                settings = json.load(f)
            cmd_apply(
                fd, settings,
                dry_run=args.dry_run,
                save_eeprom=not args.no_save,
                reset=not args.no_reset,
            )

        elif args.command == "factory":
            print("Applying factory defaults:\n")
            cmd_apply(
                fd, FACTORY_DEFAULTS,
                dry_run=args.dry_run,
                save_eeprom=not args.no_save,
                reset=not args.no_reset,
            )

    finally:
        if fd is not None:
            os.close(fd)
            print("\nPort closed.")


if __name__ == "__main__":
    main()
