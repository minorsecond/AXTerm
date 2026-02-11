#!/bin/sh
set -eu

# Upload dSYMs to Sentry when building distributable artifacts.
# Safe to run in local development: it exits cleanly when required env vars are missing.

STAMP_FILE="${DERIVED_FILE_DIR:-/tmp}/sentry_dsym_upload.stamp"
mkdir -p "$(dirname "${STAMP_FILE}")"

if [ "${ENABLE_SENTRY_DSYM_UPLOAD:-NO}" != "YES" ]; then
  echo "[sentry-dsym] Skipping upload (ENABLE_SENTRY_DSYM_UPLOAD != YES)."
  touch "${STAMP_FILE}"
  exit 0
fi

if [ -z "${SENTRY_AUTH_TOKEN:-}" ] || [ -z "${SENTRY_ORG:-}" ] || [ -z "${SENTRY_PROJECT:-}" ]; then
  echo "[sentry-dsym] Skipping upload (missing one of: SENTRY_AUTH_TOKEN, SENTRY_ORG, SENTRY_PROJECT)."
  touch "${STAMP_FILE}"
  exit 0
fi

if ! command -v sentry-cli >/dev/null 2>&1; then
  echo "[sentry-dsym] sentry-cli not found in PATH."
  touch "${STAMP_FILE}"
  exit 1
fi

DSYM_DIR="${DWARF_DSYM_FOLDER_PATH:-}"
if [ -z "${DSYM_DIR}" ] || [ ! -d "${DSYM_DIR}" ]; then
  echo "[sentry-dsym] No dSYM directory available at DWARF_DSYM_FOLDER_PATH='${DWARF_DSYM_FOLDER_PATH:-}'."
  touch "${STAMP_FILE}"
  exit 0
fi

echo "[sentry-dsym] Uploading dSYMs from '${DSYM_DIR}'"
sentry-cli debug-files upload \
  --org "${SENTRY_ORG}" \
  --project "${SENTRY_PROJECT}" \
  --include-sources \
  "${DSYM_DIR}"

echo "[sentry-dsym] Upload complete."
touch "${STAMP_FILE}"
