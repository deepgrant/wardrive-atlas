#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(awk '/MARKETING_VERSION:/ { print $2; exit }' "${ROOT}/project.yml")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "${ROOT}" rev-list --count HEAD 2>/dev/null || printf '1')}"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT}/dist}"
BUILD_DIR="${BUILD_DIR:-${ROOT}/build/release-${VERSION}}"
DMG_ROOT="${BUILD_DIR}/dmg-root"
DMG_NAME="WardriveAtlas-${VERSION}-arm64.dmg"
DMG="${OUTPUT_DIR}/${DMG_NAME}"
CHECKSUM="${DMG}.sha256"
MANIFEST="${OUTPUT_DIR}/WardriveAtlas-${VERSION}-arm64-release.json"
SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:--}"
NOTARIZE="${NOTARIZE:-0}"
PREBUILT_APP="${PREBUILT_APP:-}"

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Version must look like 1.2.3 or 1.2.3-beta.1." >&2
  exit 1
fi

if [[ -z "${PREBUILT_APP}" ]]; then
  echo "PREBUILT_APP is required; use ./gradlew dmg to build and package WardriveAtlas." >&2
  exit 1
fi
APP="${PREBUILT_APP}"
if [[ ! -d "${APP}" ]]; then
  echo "Application bundle was not found: ${APP}" >&2
  exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${DMG_ROOT}" "${OUTPUT_DIR}"
rm -f "${DMG}" "${CHECKSUM}" "${MANIFEST}"

if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  SIGNING_DESCRIPTION="ad-hoc"
else
  : "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID when using a Developer ID identity}"
  SIGNING_DESCRIPTION="Developer ID"
fi

cp -R "${APP}" "${DMG_ROOT}/WardriveAtlas.app"
ln -s /Applications "${DMG_ROOT}/Applications"

codesign --verify --deep --strict --verbose=2 "${DMG_ROOT}/WardriveAtlas.app"

FRAMEWORK="${DMG_ROOT}/WardriveAtlas.app/Contents/Frameworks/WardriveAtlasCore.framework"
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  for COMPONENT in "${DMG_ROOT}/WardriveAtlas.app" "${FRAMEWORK}"; do
    SIGNATURE_DETAILS="$(codesign -dvvv "${COMPONENT}" 2>&1)"
    if grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"${SIGNATURE_DETAILS}"; then
      echo "Ad-hoc component unexpectedly uses Hardened Runtime: ${COMPONENT}" >&2
      echo "This would cause dyld library validation to reject WardriveAtlasCore." >&2
      exit 1
    fi
  done
else
  APP_TEAM="$(codesign -dvvv "${DMG_ROOT}/WardriveAtlas.app" 2>&1 |
    awk -F= '/^TeamIdentifier=/{ print $2; exit }')"
  FRAMEWORK_TEAM="$(codesign -dvvv "${FRAMEWORK}" 2>&1 |
    awk -F= '/^TeamIdentifier=/{ print $2; exit }')"
  if [[ -z "${APP_TEAM}" || "${APP_TEAM}" != "${FRAMEWORK_TEAM}" ]]; then
    echo "The app and WardriveAtlasCore framework do not share a signing Team ID." >&2
    exit 1
  fi
fi

echo "Creating ${DMG_NAME}..."
hdiutil create \
  -volname "WardriveAtlas ${VERSION}" \
  -srcfolder "${DMG_ROOT}" \
  -ov \
  -format UDZO \
  "${DMG}"

if [[ "${SIGNING_IDENTITY}" != "-" ]]; then
  codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DMG}"
  codesign --verify --verbose=2 "${DMG}"
fi

NOTARIZED=false
if [[ "${NOTARIZE}" == "1" ]]; then
  if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
    echo "Notarization requires a Developer ID-signed build." >&2
    exit 1
  fi

  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    xcrun notarytool submit "${DMG}" \
      --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" \
      --wait
  elif [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]]; then
    xcrun notarytool submit "${DMG}" \
      --key "${APPLE_API_KEY_PATH}" \
      --key-id "${APPLE_API_KEY_ID}" \
      --issuer "${APPLE_API_ISSUER_ID}" \
      --wait
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    xcrun notarytool submit "${DMG}" \
      --apple-id "${APPLE_ID}" \
      --team-id "${APPLE_TEAM_ID}" \
      --password "${APPLE_APP_PASSWORD}" \
      --wait
  else
    echo "Set a notary keychain profile, App Store Connect API key, or Apple ID notarization credentials." >&2
    exit 1
  fi

  xcrun stapler staple "${DMG}"
  xcrun stapler validate "${DMG}"
  NOTARIZED=true
fi

(
  cd "${OUTPUT_DIR}"
  shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256"
)

COMMIT="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || printf 'unknown')"
GIT_DIRTY=false
if [[ -n "$(git -C "${ROOT}" status --porcelain 2>/dev/null)" ]]; then
  GIT_DIRTY=true
fi
CREATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
DMG_SHA256="$(awk '{ print $1 }' "${CHECKSUM}")"
cat > "${MANIFEST}" <<EOF
{
  "application": "WardriveAtlas",
  "version": "${VERSION}",
  "build": "${BUILD_NUMBER}",
  "architecture": "arm64",
  "minimumMacOS": "26.0",
  "gitCommit": "${COMMIT}",
  "workingTreeDirty": ${GIT_DIRTY},
  "createdAt": "${CREATED_AT}",
  "signing": "${SIGNING_DESCRIPTION}",
  "notarized": ${NOTARIZED},
  "dmg": "${DMG_NAME}",
  "sha256": "${DMG_SHA256}"
}
EOF

echo
echo "Release package created:"
echo "  ${DMG}"
echo "  ${CHECKSUM}"
echo "  ${MANIFEST}"
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  echo
  echo "This is an ad-hoc signed development build. Use Developer ID signing and"
  echo "notarization before presenting it as a trusted public download."
fi
