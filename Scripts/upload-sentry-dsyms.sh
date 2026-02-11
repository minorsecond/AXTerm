#!/bin/sh
set -eu

# Upload dSYMs to Sentry and optionally verify uploaded UUIDs.
# Strict mode fails the build on any upload/verification issue.

STAMP_FILE="${DERIVED_FILE_DIR:-/tmp}/sentry_dsym_upload.stamp"
mkdir -p "$(dirname "${STAMP_FILE}")"
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

CONFIG="${CONFIGURATION:-Debug}"
ACTION_NAME="${ACTION:-build}"
UPLOAD_WAIT_SECS="${SENTRY_DSYM_UPLOAD_WAIT_SECS:-120}"
VERIFY_RETRIES="${SENTRY_DSYM_VERIFY_RETRIES:-12}"
VERIFY_SLEEP_SECS="${SENTRY_DSYM_VERIFY_SLEEP_SECS:-5}"

if [ "${CONFIG}" = "Release" ]; then
  DEFAULT_ORG="axterm"
  DEFAULT_PROJECT="axterm"
  DEFAULT_VERIFY_UUIDS="YES"
else
  DEFAULT_ORG="axterm-dev"
  DEFAULT_PROJECT="axterm-dev"
  DEFAULT_VERIFY_UUIDS="NO"
fi

ORG="${SENTRY_ORG:-$DEFAULT_ORG}"
PROJECT="${SENTRY_PROJECT:-$DEFAULT_PROJECT}"
STRICT_UPLOAD="${REQUIRE_SENTRY_DSYM_UPLOAD:-NO}"
VERIFY_UUIDS="${VERIFY_SENTRY_DSYM_UUIDS:-$DEFAULT_VERIFY_UUIDS}"
SENTRY_URL_BASE="${SENTRY_URL:-https://sentry.io/}"
SENTRY_URL_BASE="${SENTRY_URL_BASE%/}"

# Release archive/install builds should enforce upload by default.
if [ "${STRICT_UPLOAD}" != "YES" ] && [ "${CONFIG}" = "Release" ] && [ "${ACTION_NAME}" = "install" ]; then
  STRICT_UPLOAD="YES"
fi

maybe_fail() {
  MESSAGE="$1"
  if [ "${STRICT_UPLOAD}" = "YES" ]; then
    echo "[sentry-dsym] ERROR: ${MESSAGE}"
    exit 1
  fi
  echo "[sentry-dsym] ${MESSAGE}"
  touch "${STAMP_FILE}"
  exit 0
}

resolve_sentry_cli() {
  if [ -n "${SENTRY_CLI_PATH:-}" ] && [ -x "${SENTRY_CLI_PATH}" ]; then
    echo "${SENTRY_CLI_PATH}"
    return 0
  fi

  if command -v sentry-cli >/dev/null 2>&1; then
    command -v sentry-cli
    return 0
  fi

  if command -v xcrun >/dev/null 2>&1; then
    XCRUN_PATH="$(xcrun --find sentry-cli 2>/dev/null || true)"
    if [ -n "${XCRUN_PATH}" ] && [ -x "${XCRUN_PATH}" ]; then
      echo "${XCRUN_PATH}"
      return 0
    fi
  fi

  for candidate in /opt/homebrew/bin/sentry-cli /usr/local/bin/sentry-cli; do
    if [ -x "${candidate}" ]; then
      echo "${candidate}"
      return 0
    fi
  done

  return 1
}

read_sentryclirc_value() {
  SECTION="$1"
  KEY="$2"
  SENTRY_RC="${SENTRY_PROPERTIES:-$HOME/.sentryclirc}"
  if [ ! -f "${SENTRY_RC}" ]; then
    return 1
  fi

  awk -F '=' -v section="${SECTION}" -v key="${KEY}" '
    /^[[:space:]]*\[/ {
      current = $0
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", current)
      next
    }
    current == section {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/ || line ~ /^;/ || line !~ /=/) {
        next
      }
      k = line
      sub(/=.*/, "", k)
      gsub(/[[:space:]]/, "", k)
      if (k == key) {
        v = line
        sub(/^[^=]*=/, "", v)
        sub(/^[[:space:]]+/, "", v)
        sub(/[[:space:]]+$/, "", v)
        print v
        exit 0
      }
    }
  ' "${SENTRY_RC}"
}

if [ -z "${SENTRY_URL:-}" ]; then
  RC_URL="$(read_sentryclirc_value defaults url || true)"
  if [ -n "${RC_URL}" ]; then
    SENTRY_URL_BASE="${RC_URL%/}"
  fi
fi

extract_uuid_file() {
  OUT_FILE="$1"
  : > "${OUT_FILE}"
  dwarfdump --uuid "${DSYM_BUNDLE_PATH}" 2>/dev/null | awk '/UUID:/ { print toupper($2) }' >> "${OUT_FILE}"
  sort -u "${OUT_FILE}" -o "${OUT_FILE}"
}

uuid_present_in_sentry() {
  UUID="$1"
  UUID_LC=$(echo "${UUID}" | tr '[:upper:]' '[:lower:]')

  Q1="${SENTRY_URL_BASE}/api/0/projects/${ORG}/${PROJECT}/files/dsyms/?debug_id=${UUID}"
  Q2="${SENTRY_URL_BASE}/api/0/projects/${ORG}/${PROJECT}/files/dsyms/?debugId=${UUID}"
  Q3="${SENTRY_URL_BASE}/api/0/projects/${ORG}/${PROJECT}/files/dsyms/?query=${UUID}"

  for url in "${Q1}" "${Q2}" "${Q3}"; do
    RESPONSE="$(curl -fsSL -H "Authorization: Bearer ${AUTH_TOKEN}" "${url}" 2>/dev/null || true)"
    if [ -n "${RESPONSE}" ] && echo "${RESPONSE}" | tr '[:upper:]' '[:lower:]' | grep -q "${UUID_LC}"; then
      return 0
    fi
  done

  return 1
}

verify_uploaded_uuids() {
  UUID_FILE="$(mktemp -t axterm_sentry_uuids.XXXXXX)"
  extract_uuid_file "${UUID_FILE}"

  if [ ! -s "${UUID_FILE}" ]; then
    rm -f "${UUID_FILE}"
    maybe_fail "Could not extract any UUIDs from .dSYM bundles."
  fi

  AUTH_TOKEN="${SENTRY_AUTH_TOKEN:-}"
  if [ -z "${AUTH_TOKEN}" ]; then
    AUTH_TOKEN="$(read_sentryclirc_value auth token || true)"
  fi
  if [ -z "${AUTH_TOKEN}" ]; then
    rm -f "${UUID_FILE}"
    maybe_fail "No SENTRY_AUTH_TOKEN found for UUID verification."
  fi

  echo "[sentry-dsym] Verifying uploaded UUIDs in Sentry (${ORG}/${PROJECT})"
  MISSING_FILE="$(mktemp -t axterm_sentry_missing_uuids.XXXXXX)"
  : > "${MISSING_FILE}"

  while IFS= read -r UUID; do
    [ -z "${UUID}" ] && continue

    ATTEMPT=1
    FOUND="NO"
    while [ "${ATTEMPT}" -le "${VERIFY_RETRIES}" ]; do
      if uuid_present_in_sentry "${UUID}"; then
        FOUND="YES"
        break
      fi
      if [ "${ATTEMPT}" -lt "${VERIFY_RETRIES}" ]; then
        sleep "${VERIFY_SLEEP_SECS}"
      fi
      ATTEMPT=$((ATTEMPT + 1))
    done

    if [ "${FOUND}" != "YES" ]; then
      echo "${UUID}" >> "${MISSING_FILE}"
    fi
  done < "${UUID_FILE}"

  if [ -s "${MISSING_FILE}" ]; then
    echo "[sentry-dsym] Missing UUIDs after upload:"
    cat "${MISSING_FILE}"
    rm -f "${UUID_FILE}" "${MISSING_FILE}"
    maybe_fail "Sentry UUID verification failed."
  fi

  rm -f "${UUID_FILE}" "${MISSING_FILE}"
  echo "[sentry-dsym] UUID verification succeeded."
}

if [ "${ENABLE_SENTRY_DSYM_UPLOAD:-NO}" != "YES" ]; then
  echo "[sentry-dsym] Skipping upload (ENABLE_SENTRY_DSYM_UPLOAD != YES)."
  touch "${STAMP_FILE}"
  exit 0
fi

SENTRY_CLI="$(resolve_sentry_cli || true)"
if [ -z "${SENTRY_CLI}" ]; then
  maybe_fail "Skipping upload: sentry-cli not found in PATH."
fi
echo "[sentry-dsym] Using sentry-cli at '${SENTRY_CLI}'"

DSYM_DIR="${DWARF_DSYM_FOLDER_PATH:-}"
DSYM_NAME="${DWARF_DSYM_FILE_NAME:-}"
DSYM_BUNDLE_PATH="${DSYM_DIR}/${DSYM_NAME}"
if [ -z "${DSYM_DIR}" ] || [ -z "${DSYM_NAME}" ] || [ ! -d "${DSYM_BUNDLE_PATH}" ]; then
  maybe_fail "No dSYM bundle at '${DSYM_BUNDLE_PATH}'."
fi

echo "[sentry-dsym] Uploading dSYM '${DSYM_BUNDLE_PATH}' (config=${CONFIG}, action=${ACTION_NAME}, org=${ORG}, project=${PROJECT})"
if ! "${SENTRY_CLI}" debug-files upload \
  --org "${ORG}" \
  --project "${PROJECT}" \
  --include-sources \
  --wait-for "${UPLOAD_WAIT_SECS}" \
  "${DSYM_BUNDLE_PATH}"
then
  maybe_fail "Upload failed."
fi

if [ "${VERIFY_UUIDS}" = "YES" ]; then
  if ! command -v curl >/dev/null 2>&1; then
    maybe_fail "curl not found; cannot verify UUIDs in Sentry."
  fi
  verify_uploaded_uuids
else
  echo "[sentry-dsym] Skipping UUID verification (VERIFY_SENTRY_DSYM_UUIDS != YES)."
fi

echo "[sentry-dsym] Upload complete."
touch "${STAMP_FILE}"
