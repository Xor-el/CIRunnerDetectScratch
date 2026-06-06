#!/usr/bin/env bash
set -euo pipefail

TARGET_ID="${1:?TARGET_ID argument required}"
: "${ENABLED_TARGETS:?ENABLED_TARGETS is required}"

if [[ ",${ENABLED_TARGETS}," == *",${TARGET_ID},"* ]]; then
  echo "enabled=true"  >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
else
  echo "enabled=false" >> "$GITHUB_OUTPUT"
  echo "::notice::Skipping ${TARGET_ID} (not in enabled targets)"
fi
