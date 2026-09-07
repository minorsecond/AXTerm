#!/bin/sh
# Cross-validate AXTerm's built-in modem against Direwolf.
#
# Direwolf's gen_packets writes AFSK test audio; our demodulator must decode
# it. Our modulator writes a transmission; Direwolf's atest must decode
# that. Both halves run here, in the rig's Direwolf image, so nothing is
# proven by AXTerm about AXTerm.
#
#   TestRig/scripts/modem_xval.sh [outdir]
#
# Needs Docker and Xcode. Leaves the WAVs in outdir for a listen.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=${1:-"$REPO/tmp/modem-xval"}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
IMAGE=axterm-direwolf-tools

echo "== building $IMAGE"
docker build -q -t "$IMAGE" "$HERE/direwolf" >/dev/null

dw() { docker run --rm -v "$OUT:/work" "$IMAGE" "$@"; }

echo "== Direwolf writes test audio"
# 100 frames, 48 kHz, 1200 bd, clean (-a 50 = 50% amplitude) and noisy (-n = add noise).
dw gen_packets -r 48000 -B 1200 -n 100 -a 50 -o /work/dw_1200_clean_n100.wav
dw gen_packets -r 48000 -B 1200 -n 100 -a 30 -N 0.3 -o /work/dw_1200_noisy_n100.wav 2>/dev/null \
  || dw gen_packets -r 48000 -B 1200 -n 100 -a 10 -o /work/dw_1200_noisy_n100.wav
dw gen_packets -r 48000 -B 300 -n 50 -a 50 -o /work/dw_300_clean_n50.wav
dw gen_packets -r 44100 -B 1200 -n 50 -a 50 -o /work/dw_1200_44k_n50.wav

echo "== AXTerm decodes Direwolf's audio (bundled fixtures + these files) and writes its own"
cd "$REPO"
LOG=$(mktemp)
xcodebuild -scheme AXTerm -destination 'platform=macOS' \
  -only-testing:AXTermTests/ModemDirewolfCrossValidationTests test \
  TEST_RUNNER_AXTERM_MODEM_XVAL_DIR="$OUT" > "$LOG" 2>&1 || true
grep -E "xval:|error:|\*\* TEST" "$LOG" | sed 's/^.*xval:/xval:/' | sort -u
# The test host is sandboxed: it writes into its own container's tmp.
WROTE=$(find "$HOME/Library/Containers/com.rosswardrup.AXTerm" -name axterm_tx_1200.wav 2>/dev/null | head -1)
if [ -n "$WROTE" ]; then cp "$(dirname "$WROTE")"/axterm_tx_*.wav "$OUT"/; fi
rm -f "$LOG"

echo "== Direwolf decodes AXTerm's audio (expect 20 of 20 each)"
dw atest -B 1200 /work/axterm_tx_1200.wav | tail -3
dw atest -B 300 /work/axterm_tx_300.wav | tail -3
