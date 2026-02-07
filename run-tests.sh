#!/bin/bash
# Run all AXTerm tests
# Usage: ./run-tests.sh [test-suite-name]
# Use -resultBundlePath so we can extract failures with xcresulttool.

set -e

SCHEME="AXTerm"
DESTINATION="platform=macOS"
RESULT_BUNDLE="${RESULT_BUNDLE:-/tmp/AXTerm-Test-Results.xcresult}"

if [ -z "$1" ]; then
    echo "Running all tests..."
    xcodebuild test \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -resultBundlePath "$RESULT_BUNDLE" \
        2>&1 | tee test-output.log
else
    echo "Running tests matching: $1"
    xcodebuild test \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -only-testing:"AXTermTests/$1" \
        -resultBundlePath "$RESULT_BUNDLE" \
        2>&1 | tee test-output.log
fi

echo ""
echo "Test results saved to test-output.log"
echo "To see pass/fail summary: grep -E 'passed|failed|skipped|TEST' test-output.log | tail -30"
echo ""

# Show summary and failures from xcresult
if command -v xcrun >/dev/null 2>&1 && [ -d "$RESULT_BUNDLE" ]; then
    echo "--- Test summary ---"
    xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>/dev/null || true
    echo ""
    echo "--- Failures / insights ---"
    xcrun xcresulttool get test-results insights --path "$RESULT_BUNDLE" 2>/dev/null || true
fi
