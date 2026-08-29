#!/bin/sh
# Everything at once: a rough channel, a hostile fuzzer, and a
# misbehaving digipeater — the worst afternoon a station ever has.
# Run with AXTerm connected to the rig and watch it cope.
set -e
DIR=$(dirname "$0")
HOST=${1:-127.0.0.1}
PORT=${2:-8010}

echo "Roughening the channel to 15% loss, 150ms delay..."
( cd "$DIR/.." && LOSS=0.15 DELAY_MS=150 JITTER_MS=100 docker compose up -d kisshub )
sleep 2

echo "Starting a misbehaving digipeater (RELAY: dupes, delay, corruption)..."
python3 "$DIR/bad_digipeater.py" "$HOST" "$PORT" \
    --alias RELAY --dupe 0.3 --delay 200 --corrupt 0.2 &
DIGI=$!

echo "Spraying hostile frames for 120s..."
python3 "$DIR/fuzz_channel.py" "$HOST" "$PORT" --seconds 120 --rate 25 || true

kill $DIGI 2>/dev/null || true
echo "Chaos over. Restoring a clean channel..."
( cd "$DIR/.." && LOSS=0 DELAY_MS=0 JITTER_MS=0 docker compose up -d kisshub )
echo "If AXTerm survived that, it survives the real band on a bad day."
