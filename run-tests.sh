#!/bin/bash
# Run all AXTerm tests
# Usage: ./run-tests.sh [test-suite-name]

set -e

SCHEME="AXTerm"
DESTINATION="platform=macOS"

if [ -z "$1" ]; then
    echo "Running all tests..."
    xcodebuild test \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        2>&1 | tee test-output.log
else
    echo "Running tests matching: $1"
    xcodebuild test \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -only-testing:"AXTermTests/$1" \
        2>&1 | tee test-output.log
fi

echo ""
echo "Test results saved to test-output.log"
echo "To see just pass/fail summary: grep -E 'passed|failed|TEST' test-output.log | tail -20"
