#!/bin/sh
set -e
export HOME=/root

: "${MYCALL:=N0CALL}"
: "${KISSPORT:=8001}"
# Standard New-N: repeat WIDE1-1/2 and WIDE2-1/2, substituting our own callsign
# and marking it used (TRACE), which is what a real fill-in digi does.
: "${DIGIPEAT:=}"

# Two modes:
#   PULSE_SERVER set  -> this modem is one radio among several on the shared
#                        ether container (profile `rfnet`). Nothing local.
#   unset             -> the original single-modem self-loopback (profile `rf`).
if [ -n "$PULSE_SERVER" ]; then
  echo "[modem $MYCALL] joining shared ether at $PULSE_SERVER"
  for _ in $(seq 1 60); do
    pactl info >/dev/null 2>&1 && break
    sleep 0.5
  done
  pactl info >/dev/null 2>&1 || { echo "[modem $MYCALL] no ether" >&2; exit 1; }
else
  pulseaudio --daemonize=yes --exit-idle-time=-1 --disallow-exit=yes \
      --load="module-null-sink sink_name=rf sink_properties=device.description=RFChannel" \
      --load="module-native-protocol-unix"
  sleep 1
  pactl set-default-sink rf
  pactl set-default-source rf.monitor
  echo "PulseAudio loopback up: sink=rf source=rf.monitor"
fi

sed -e "s/@MYCALL@/$MYCALL/" -e "s/@KISSPORT@/$KISSPORT/" \
    -e "s|@DIGIPEAT@|$DIGIPEAT|" \
    /etc/direwolf.conf.in > /etc/direwolf.conf
[ -n "$DIGIPEAT" ] && echo "[modem $MYCALL] digipeating: $DIGIPEAT"
exec direwolf -t 0 -c /etc/direwolf.conf
