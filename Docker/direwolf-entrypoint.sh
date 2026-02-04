#!/bin/bash
# Direwolf entrypoint script for AXTerm testing
#
# This script starts PulseAudio for virtual audio, then launches Direwolf
# with KISS TCP enabled for AXTerm to connect to.

set -e

echo "========================================"
echo "Direwolf TNC - AXTerm Test Environment"
echo "========================================"
echo "Callsign: ${MYCALL}"
echo "KISS Port: ${KISS_PORT}"
echo "========================================"

# Generate Direwolf configuration
cat > /etc/direwolf/direwolf.conf << EOF
# Direwolf configuration for AXTerm testing
# Auto-generated - do not edit

# Station identification
MYCALL ${MYCALL}

# Audio configuration - use PulseAudio
ADEVICE ${AUDIO_DEVICE:-pulse}
ARATE 48000
ACHANNELS 1

# Channel 0 settings
CHANNEL 0
# MODEM baud rate is configurable via MODEM_SPEED env (300/1200/9600, etc.)
MODEM ${MODEM_SPEED:-1200}
PTT NONE

# KISS TCP interface for AXTerm
KISSPORT ${KISS_PORT}

# AGW interface (disabled for KISS-only testing)
# AGWPORT 8000

# Beacon (disabled for testing)
# PBEACON delay=1 every=30 overlay=S symbol="nws" lat=0 long=0 comment="Test"

# Digipeater (disabled for testing)
# DIGIPEAT 0 0 ^WIDE[3-7]-[1-7]$ ^WIDE[12]-[12]$

# Logging
LOGDIR /var/log/direwolf
EOF

# Start PulseAudio daemon in the background if not using null audio
if [ "${AUDIO_DEVICE}" != "null" ]; then
    echo "Starting PulseAudio..."
    pulseaudio --start --exit-idle-time=-1 2>/dev/null || true
    sleep 1
fi

# Start Direwolf
echo "Starting Direwolf..."
exec direwolf -c /etc/direwolf/direwolf.conf -t 0 ${DIREWOLF_OPTS}
