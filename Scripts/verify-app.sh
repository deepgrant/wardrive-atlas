#!/usr/bin/env bash
set -euo pipefail

APP="${1:?Pass the WardriveAtlas.app path to verify}"
SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:--}"
FRAMEWORK="${APP}/Contents/Frameworks/WardriveAtlasCore.framework"

if [[ ! -d "${APP}" ]]; then
  echo "Application bundle was not found: ${APP}" >&2
  exit 1
fi
if [[ ! -d "${FRAMEWORK}" ]]; then
  echo "WardriveAtlasCore framework was not found: ${FRAMEWORK}" >&2
  exit 1
fi

for EXECUTABLE in "${APP}/Contents/MacOS/WardriveAtlas" "${FRAMEWORK}/WardriveAtlasCore"; do
  if [[ "$(lipo -archs "${EXECUTABLE}")" != "arm64" ]]; then
    echo "Expected an arm64 executable: ${EXECUTABLE}" >&2
    exit 1
  fi
done
if [[ ! -f "${FRAMEWORK}/Resources/catalog.json" ]]; then
  echo "The bundled detection catalog is missing." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "${APP}"

if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  for COMPONENT in "${APP}" "${FRAMEWORK}"; do
    SIGNATURE_DETAILS="$(codesign -dvvv "${COMPONENT}" 2>&1)"
    if grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"${SIGNATURE_DETAILS}"; then
      echo "Ad-hoc component unexpectedly uses Hardened Runtime: ${COMPONENT}" >&2
      echo "This would cause dyld library validation to reject WardriveAtlasCore." >&2
      exit 1
    fi
  done
else
  : "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID when using a Developer ID identity}"
  APP_TEAM="$(codesign -dvvv "${APP}" 2>&1 |
    awk -F= '/^TeamIdentifier=/{ print $2; exit }')"
  FRAMEWORK_TEAM="$(codesign -dvvv "${FRAMEWORK}" 2>&1 |
    awk -F= '/^TeamIdentifier=/{ print $2; exit }')"
  if [[ -z "${APP_TEAM}" || "${APP_TEAM}" != "${FRAMEWORK_TEAM}" ]]; then
    echo "The app and WardriveAtlasCore framework do not share a signing Team ID." >&2
    exit 1
  fi
  if [[ "${APP_TEAM}" != "${APPLE_TEAM_ID}" ]]; then
    echo "The application Team ID does not match APPLE_TEAM_ID." >&2
    exit 1
  fi
fi

echo "Application signature verified: ${APP}"
