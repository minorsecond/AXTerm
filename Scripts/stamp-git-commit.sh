#!/bin/sh
#
# Stamp the commit this build came from into the app's Info.plist, where
# SentryConfiguration reads it as SENTRY_GIT_COMMIT.
#
# The xcconfigs ship "unknown", which the configuration treats as absent, so
# without this every event arrives with no commit attached. AXTerm used to
# read the commit at runtime by forking git from a SwiftUI body; that pumped
# the run loop mid-layout and crashed the settings window. Build time is the
# right place for it.
#
# Never fails the build. No git, no repository, a source tarball: the plist
# keeps whatever the xcconfig gave it.

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
[ -f "${PLIST}" ] || exit 0

if [ "${SENTRY_SKIP_GIT_STAMP}" = "1" ]; then
    exit 0
fi

SHA=$(git -C "${SRCROOT}" rev-parse --short=12 HEAD 2>/dev/null)
[ -n "${SHA}" ] || exit 0

# An uncommitted tree is not the commit it claims to be, and a Sentry event
# pointing at the wrong source is worse than one pointing at nothing.
if ! git -C "${SRCROOT}" diff --quiet HEAD 2>/dev/null; then
    SHA="${SHA}-dirty"
fi

/usr/libexec/PlistBuddy -c "Set :SENTRY_GIT_COMMIT ${SHA}" "${PLIST}" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :SENTRY_GIT_COMMIT string ${SHA}" "${PLIST}" 2>/dev/null \
    || exit 0

echo "note: SENTRY_GIT_COMMIT = ${SHA}"
