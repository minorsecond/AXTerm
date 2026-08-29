#!/bin/sh
set -e
export HOME=/root
pulseaudio --daemonize=yes --exit-idle-time=-1 --disallow-exit=yes \
    --load="module-null-sink sink_name=rf sink_properties=device.description=RFChannel" \
    --load="module-native-protocol-unix"
sleep 1
pactl set-default-sink rf
pactl set-default-source rf.monitor
echo "PulseAudio loopback up: sink=rf source=rf.monitor"
exec direwolf -t 0 -c /etc/direwolf.conf
