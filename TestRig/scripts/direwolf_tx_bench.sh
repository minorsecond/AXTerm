#!/usr/bin/env bash
#
# Transmit test frames with Direwolf, bypassing Warbler's modulator.
#
# Warbler drives its radio over the SCU-LAN10 and holds the only session, so
# the way to test the radio without Warbler's AFSK is to use the other path
# into it: the DigiRig and the CM108 sound card that Direwolf already owns.
# This swaps Direwolf to the baud rate under test, sends frames, and puts the
# normal configuration back.
#
# Written on 2026-09-19 after a bench session where Warbler's 300 bd
# transmissions decoded at 4% into a receiver 32 dB out of the noise, while
# AXTerm's decoded first time through a dummy load. Everything measurable about
# Warbler's signal was correct, so the question became whether the radio and
# the path are fine and the modulator is not — which is what this answers.
#
# IT TRANSMITS. Check what the DigiRig is plugged into, and what frequency
# that radio is on, before running it.
#
# Usage:
#   direwolf_tx_bench.sh --confirm [--host ham-pi] [--baud 300] [--count 3]
#                        [--call K0EPI-1] [--text "..."]
#
set -euo pipefail

HOST=ham-pi; BAUD=300; COUNT=3; CALL=K0EPI-1; DEST=CQ; CONFIRM=0
TEXT="A0123456789B0123456789C0123456789D0123456789E0123456789F0123456789G0123456789H0123456789I0123456789J0123456789K0123456789L012345"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST=$2; shift 2;;
    --baud) BAUD=$2; shift 2;;
    --count) COUNT=$2; shift 2;;
    --call) CALL=$2; shift 2;;
    --dest) DEST=$2; shift 2;;
    --text) TEXT=$2; shift 2;;
    --confirm) CONFIRM=1; shift;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

if [ "$CONFIRM" != 1 ]; then
  cat >&2 <<EOF
This keys a radio. Re-run with --confirm once you have checked:
  - what the DigiRig on $HOST is connected to
  - that the radio is on a frequency you may transmit on, at low power
  - that ${BAUD} baud suits that radio's mode (300 = SSB data, 1200 = FM)
EOF
  exit 1
fi

echo "== $HOST: swapping Direwolf to ${BAUD} baud, sending ${COUNT} frame(s) as ${CALL}"

ssh "$HOST" "BAUD='$BAUD' COUNT='$COUNT' CALL='$CALL' DEST='$DEST' TEXT='$TEXT' bash -s" <<'REMOTE'
set -euo pipefail
CONF=$HOME/direwolf.conf
BENCH=/tmp/direwolf-bench.conf

# Same sound card and PTT, different baud, KISS on a port of its own so the
# swap cannot be confused with the service that normally answers on 8001.
sed -e "s/^MODEM .*/MODEM $BAUD/" \
    -e "s/^MYCALL .*/MYCALL $CALL/" \
    -e "s/^KISSPORT .*/KISSPORT 8011/" \
    -e "s/^AGWPORT .*/AGWPORT 8010/" "$CONF" > "$BENCH"
echo "-- bench config:"; grep -vE '^\s*#|^\s*$' "$BENCH" | sed 's/^/     /'

restore() {
  [ -n "${DW_PID:-}" ] && kill "$DW_PID" 2>/dev/null || true
  wait "${DW_PID:-}" 2>/dev/null || true
  echo "-- restarting the normal direwolf service"
  sudo systemctl start direwolf.service
}
trap restore EXIT

echo "-- stopping direwolf.service (it owns the sound card)"
sudo systemctl stop direwolf.service
sleep 1

direwolf -c "$BENCH" -t 0 > /tmp/direwolf-bench.log 2>&1 &
DW_PID=$!
sleep 3
kill -0 "$DW_PID" 2>/dev/null || { echo "!! direwolf exited:"; tail -20 /tmp/direwolf-bench.log; exit 1; }
grep -E "baud|MODEM|Ready" /tmp/direwolf-bench.log | head -5 | sed 's/^/     /'

for i in $(seq 1 "$COUNT"); do
  printf '%s>%s:%s %d\n' "$CALL" "$DEST" "$TEXT" "$i" > /tmp/bench-frame.txt
  kissutil -h localhost -p 8011 -f /tmp/bench-frame.txt 2>&1 | sed 's/^/     kissutil: /' || true
  echo "-- sent frame $i/$COUNT"
  sleep 4
done

sleep 2
echo "-- direwolf transmit log:"
grep -aiE "\[0L?\]|xmit|ptt|audio level" /tmp/direwolf-bench.log | tail -12 | sed 's/^/     /'
REMOTE

echo "== done; direwolf.service restored"
