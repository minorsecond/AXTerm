#!/bin/sh
# Bring up: pty bridge -> config -> virtual X -> Xastir.
set -e

KISS_PTY=/tmp/kiss-pty
CFG="$HOME/.xastir/config/xastir.cnf"

echo "[xastir-rig] $CALLSIGN -> $HUB_HOST:$HUB_PORT"

# `docker compose restart` keeps the container filesystem, so two pieces of
# stale state survive and make the restart fail instead of the start:
#
#   /tmp/.X99-lock          Xvfb refuses: "Server is already active for
#                           display 99".
#   ~/.xastir/xastir.pid    Xastir refuses: "Other Xastir process, pid: 1 may
#                           be running" — and pid 1 always exists in a
#                           container, so the check can never pass.
#
# Nothing else runs in here, so both are unconditionally ours to clear.
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 "$HOME/.xastir/xastir.pid"

# 1. The pty bridge. Supervised: the hub may not be listening yet, and a hub
#    restart must not strand the station off the air for the rest of the run.
# `forever,retry` keeps *this* socat process alive across a TNC restart, which
# matters more than it looks: Xastir opens the pty once at startup and never
# reopens it, so a socat that exits and respawns hands it a new /dev/pts while
# Xastir holds the dead one. The station then sits there, apparently healthy,
# hearing nothing. The outer loop is only a backstop.
(
  while true; do
    socat "pty,raw,echo=0,link=$KISS_PTY" \
          "tcp:$HUB_HOST:$HUB_PORT,forever,intervall=1,retry=86400" \
      || echo "[xastir-rig] socat exited ($?), retrying"
    sleep 1
  done
) &

# Xastir opens the device once, at startup, and gives up if it is missing.
for _ in $(seq 1 60); do
  [ -e "$KISS_PTY" ] && break
  sleep 0.5
done
if [ ! -e "$KISS_PTY" ]; then
  echo "[xastir-rig] no pty after 30s — is the hub up?" >&2
  exit 1
fi

# 2. Config, from the template.
mkdir -p "$HOME/.xastir/config"
sed -e "s|@CALLSIGN@|$CALLSIGN|g" \
    -e "s|@STATION_LAT@|$STATION_LAT|g" \
    -e "s|@STATION_LONG@|$STATION_LONG|g" \
    -e "s|@UNPROTO1@|$UNPROTO1|g" \
    -e "s|@POSIT_RATE@|$POSIT_RATE|g" \
    -e "s|@DISABLE_POSIT_TX@|$DISABLE_POSIT_TX|g" \
    -e "s|@KISS_PTY@|$KISS_PTY|g" \
    /etc/xastir.cnf.in > "$CFG"

# 3. Xastir is X11/Motif with no headless mode. Nothing reads this display.
Xvfb :99 -screen 0 1024x768x16 -nolisten tcp &
export DISPLAY=:99
for _ in $(seq 1 40); do
  [ -e /tmp/.X11-unix/X99 ] && break
  sleep 0.25
done

# Xastir hides most interface errors behind debug bits; 2 is the interface
# one. Silent hard-fails are otherwise impossible to diagnose from a log.
if [ -n "$XASTIR_DEBUG" ] && [ "$XASTIR_DEBUG" != "0" ]; then
  exec xastir -v "$XASTIR_DEBUG"
fi
exec xastir
