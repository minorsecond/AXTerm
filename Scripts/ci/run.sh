#!/bin/bash
# AXTerm CI: one entry point for every job, so CI and a local run use the
# same flags.
#
#   Scripts/ci/run.sh unit       macOS build and the full unit suite
#   Scripts/ci/run.sh ios        iOS build
#   Scripts/ci/run.sh soak       the nightly soaks (fuzzing, property tests,
#                                every stress family, full-stack fuzz)
#
# Builds go to build/ci/DerivedData, never the shared DerivedData, so a CI
# run on a developer's Mac does not replace the app they are running from
# Xcode. Result bundles and reports go to build/ci/.
#
# Tests that need a TNC, a radio or the network are excluded by name. They
# also skip themselves without their flag files, but a leftover
# /tmp/axterm_rf_tests_enabled on the runner must never let CI transmit.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/ci"
DERIVED="$OUT/DerivedData"
mkdir -p "$OUT"
cd "$ROOT"

LIVE_TESTS=(
  RealHardwareTNCTests
  TNC4LiveConnectionTests
  TNC4SerialLiveTests
  TNC4BLEReceiveLiveTests
  TNC4BluetoothSerialConnectionTests
  MinimalTNC4ConnectTest
  DRLNODLiveTest
)
SKIP_LIVE=()
for t in "${LIVE_TESTS[@]}"; do SKIP_LIVE+=("-skip-testing:AXTermTests/$t"); done

# Where the test host writes its stress reports (sandboxed temporary folder).
REPORTS="$HOME/Library/Containers/com.rosswardrup.AXTerm/Data/tmp/AXTermStress"

xcode_test() {
  local name="$1"; shift
  rm -rf "$OUT/$name.xcresult"
  set +e
  xcodebuild test \
    -project AXTerm.xcodeproj -scheme AXTerm \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$OUT/$name.xcresult" \
    "$@" 2>&1 | tee "$OUT/$name.log" | grep -E --line-buffered "error:|' failed on|\*\* TEST|Executed"
  local status=${PIPESTATUS[0]}
  set -e
  summarize "$name" "$status"
  return "$status"
}

# A line per failing test in the job summary, when GitHub provides one.
summarize() {
  local name="$1" status="$2"
  local summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
  local passed failed
  passed=$(grep -c "' passed on" "$OUT/$name.log" || true)
  failed=$(grep -c "' failed on" "$OUT/$name.log" || true)
  {
    echo "### $name: $([ "$status" = 0 ] && echo passed || echo FAILED)"
    echo
    echo "$passed passed, $failed failed"
    if [ "$failed" != 0 ]; then
      echo
      grep "' failed on" "$OUT/$name.log" | sed -E "s/^Test case '([^']*)'.*/- \1/" | head -50
    fi
    echo
  } >> "$summary"
}

collect_reports() {
  mkdir -p "$OUT/reports"
  if [ -d "$REPORTS" ]; then cp -R "$REPORTS/." "$OUT/reports/"; fi
}

case "${1:-}" in
  unit)
    xcode_test unit -only-testing:AXTermTests "${SKIP_LIVE[@]}" -parallel-testing-worker-count 2
    ;;

  ios)
    set +e
    xcodebuild build \
      -project AXTerm.xcodeproj -scheme AXTerm-iOS \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$DERIVED" 2>&1 | tee "$OUT/ios.log" | grep -E --line-buffered "error:|\*\* BUILD"
    status=${PIPESTATUS[0]}
    set -e
    echo "### iOS build: $([ "$status" = 0 ] && echo passed || echo FAILED)" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    exit "$status"
    ;;

  soak)
    rm -rf "$REPORTS"
    failures=0
    # Two-station simulator, growth off against on, random scenarios.
    ( export TEST_RUNNER_AXTERM_GROWTH_FUZZ_SEEDS="${AXTERM_GROWTH_FUZZ_SEEDS:-5000}"
      xcode_test soak-growth-fuzz \
        -only-testing:AXTermTests/ConnectedModeStressTests/testFuzzedChannelsKeepEveryInvariantWithAndWithoutGrowth \
        -parallel-testing-worker-count 1 ) || failures=$((failures + 1))
    # Every stress family at many seeds, including the mode comparison.
    ( export TEST_RUNNER_AXTERM_STRESS_SEEDS="${AXTERM_STRESS_SEEDS:-200}"
      xcode_test soak-stress \
        -only-testing:AXTermTests/ConnectedModeStressTests \
        -skip-testing:AXTermTests/ConnectedModeStressTests/testFuzzedChannelsKeepEveryInvariantWithAndWithoutGrowth \
        -parallel-testing-worker-count 3 ) || failures=$((failures + 1))
    # Seeded property tests, a fresh seed base each night.
    ( export TEST_RUNNER_AXTERM_FUZZ_ITERATIONS="${AXTERM_FUZZ_ITERATIONS:-20000}"
      export TEST_RUNNER_AXTERM_FUZZ_BASE="${AXTERM_FUZZ_BASE:-$(date +%Y%m%d)}"
      xcode_test soak-properties \
        -only-testing:AXTermTests/KISSAX25DecodePropertyTests \
        -only-testing:AXTermTests/AX25T1TimerPropertyTests \
        -only-testing:AXTermTests/AX25SessionStatePropertyTests \
        -only-testing:AXTermTests/MobilinkdReplyPropertyTests \
        -only-testing:AXTermTests/NetRomNodesBroadcastPropertyTests \
        -parallel-testing-worker-count 3 ) || failures=$((failures + 1))
    # The sound modem with noise. Each case decodes about a second of
    # audio, so it gets far fewer cases than the properties above.
    ( export TEST_RUNNER_AXTERM_FUZZ_ITERATIONS="${AXTERM_MODEM_FUZZ_ITERATIONS:-2000}"
      export TEST_RUNNER_AXTERM_FUZZ_BASE="${AXTERM_FUZZ_BASE:-$(date +%Y%m%d)}"
      xcode_test soak-modem \
        -only-testing:AXTermTests/AFSKNoisePropertyTests \
        -parallel-testing-worker-count 1 ) || failures=$((failures + 1))
    # Two complete stations over an impaired link: transfers and chat,
    # Winlink, the mailbox and the node shell.
    ( export TEST_RUNNER_AXTERM_FULLSTACK_FUZZ_SEEDS="${AXTERM_FULLSTACK_FUZZ_SEEDS:-200}"
      export TEST_RUNNER_AXTERM_FULLSTACK_FUZZ_BASE="${AXTERM_FULLSTACK_FUZZ_BASE:-$(date +%Y%m%d)000}"
      export TEST_RUNNER_AXTERM_FULLSTACK_FUZZ_TRACE=1
      xcode_test soak-fullstack \
        -only-testing:AXTermTests/FullStackTransferFuzzTests \
        -only-testing:AXTermTests/FullStackWinlinkFuzzTests \
        -only-testing:AXTermTests/FullStackBBSFuzzTests \
        -only-testing:AXTermTests/FullStackNodeFuzzTests \
        -parallel-testing-worker-count 1 ) || failures=$((failures + 1))
    collect_reports
    exit "$failures"
    ;;

  *)
    echo "usage: $0 unit|ios|soak" >&2
    exit 2
    ;;
esac
