#!/bin/sh
set -e
export HOME=/root

# The unix socket is for our own pactl, which sets the defaults and the channel
# level; without it those calls fail "Connection refused" while the modems --
# which come in over TCP -- carry on regardless, so the misconfiguration is
# invisible except as an overdriven channel.
#
# anonymous auth: this is a closed test network, and the alternative is
# shipping a cookie into every modem container.
pulseaudio --exit-idle-time=-1 --disallow-exit=yes -n \
  --load="module-null-sink sink_name=rf sink_properties=device.description=RFChannel" \
  --load="module-native-protocol-tcp port=4713 listen=0.0.0.0 auth-anonymous=1" \
  --load="module-native-protocol-unix" \
  --load="module-always-sink" \
  --log-target=stderr &
PA=$!

for _ in $(seq 1 40); do
  pactl info >/dev/null 2>&1 && break
  sleep 0.25
done
pactl set-default-sink rf
pactl set-default-source rf.monitor

# Direwolf wants received audio around 50 and complains above ~100. Everything
# played into a null sink comes back out of its monitor at full scale, which
# lands every modem at ~198 — decodable, but clipped, and clipping is exactly
# what makes a marginal collision undecodable for the wrong reason.
: "${ETHER_VOLUME:=25%}"
pactl set-sink-volume rf "$ETHER_VOLUME"
echo "[rf-ether] channel level $ETHER_VOLUME"
echo "[rf-ether] shared channel up: sink=rf source=rf.monitor on :4713"
pactl list short modules | sed 's/^/[rf-ether] /'
wait $PA
