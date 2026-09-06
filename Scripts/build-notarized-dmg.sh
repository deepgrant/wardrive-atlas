#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Developer ID Application identity}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to your Apple Developer team ID}"

ARGS=(dmg)
if [[ -n "${VERSION}" ]]; then
  if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Version must be semantic, for example 0.1.0" >&2
    exit 1
  fi
  ARGS+=("-PwardriveAtlasVersion=${VERSION}")
fi

NOTARIZE=1 exec "${ROOT}/gradlew" "${ARGS[@]}"
