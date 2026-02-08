#!/bin/bash
# Audio bridge entrypoint for AXTerm Direwolf testing
#
# This creates a shared PulseAudio server that acts as a virtual
# "RF channel" - all Direwolf instances connect to it and can
# hear each other's transmissions.

set -e

echo "========================================"
echo "AXTerm Audio Bridge"
echo "========================================"
echo "Creating virtual RF channel for Direwolf"
echo "========================================"

# Create runtime directory
mkdir -p /run/pulse
chmod 755 /run/pulse

# Configure PulseAudio for daemon mode with network access
cat > /etc/pulse/daemon.conf << EOF
daemonize = no
allow-module-loading = yes
allow-exit = no
use-pid-file = no
system-instance = yes
local-server-type = system
enable-shm = no
flat-volumes = no
default-sample-format = s16le
default-sample-rate = 48000
default-sample-channels = 1
exit-idle-time = -1
EOF

# Create the default.pa with our RF channel configuration
cat > /etc/pulse/default.pa << EOF
#!/usr/bin/pulseaudio -nF

# Basic modules
load-module module-device-restore
load-module module-stream-restore
load-module module-card-restore

# Create the "RF Channel" - a virtual audio device
# All Direwolf TX goes here, and all Direwolf RX listens to this
load-module module-null-sink sink_name=rf_channel sink_properties=device.description="RF_Channel"

# Make the RF channel monitor available as a source
load-module module-remap-source master=rf_channel.monitor source_name=rf_source source_properties=device.description="RF_Monitor"

# Enable TCP access for Direwolf containers
load-module module-native-protocol-tcp auth-anonymous=1 port=4713

# Set defaults
set-default-sink rf_channel
set-default-source rf_source
EOF

echo "Starting PulseAudio server on port 4713..."

# Run PulseAudio in foreground
exec pulseaudio --system --disallow-exit --disallow-module-loading=0 --log-level=notice
