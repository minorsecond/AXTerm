#!/bin/bash
# Capture both feeds of the same air for a window, and compare them.
#
#   ./live_feed_capture.sh [minutes]
#
# Ours is AXTerm's own `packets` table — whatever the radios heard. Theirs is
# the APRS-IS stream aprs.fi displays, read directly: aprs.fi's API answers
# "where is this station now", which cannot tell you what was missed half an
# hour ago. The login uses passcode -1, which APRS-IS accepts for receive and
# refuses for transmit, so nothing here can put a byte on the air.
#
# Produces three things:
#   1. a station-by-station comparison (compare_feeds.py) — who we heard, who
#      was gated, which of our frames reached the internet
#   2. AXTermTests/Fixtures/live-feed-parity.json — every frame from both
#      feeds with Direwolf's decode, which `LiveFeedParityTests` checks our
#      parsers against
#
# Needs decode_aprs on PATH and direwolf's data/tocalls.yaml (brew install
# direwolf, plus a clone for the data directory).
set -euo pipefail
cd "$(dirname "$0")"

MINUTES="${1:-30}"
CALL="${CALL:-$(defaults read com.rosswardrup.AXTerm myCallsign)}"
LAT="${LAT:-39.6117}"
LON="${LON:--104.7317}"
OUT="${OUT:-$TMPDIR/aprsis-capture.jsonl}"

echo "capturing $MINUTES minutes of APRS-IS as $CALL around $LAT,$LON"
python3 aprsis_capture.py --call "$CALL" --lat "$LAT" --lon "$LON" \
    --radius-km 150 --seconds "$((MINUTES * 60))" --out "$OUT"

echo
python3 compare_feeds.py --capture "$OUT"

echo
python3 decode_both.py --capture "$OUT" --out ../../AXTermTests/Fixtures/live-feed-parity.json
echo "now run: xcodebuild test -only-testing:AXTermTests/LiveFeedParityTests"
