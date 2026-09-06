#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"

ARGS=(buildApp)
if [[ -n "${VERSION}" ]]; then
  if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Version must be semantic, for example 0.1.0" >&2
    exit 1
  fi
  ARGS+=("-PwardriveAtlasVersion=${VERSION}")
fi

exec "${ROOT}/gradlew" "${ARGS[@]}"
