#!/usr/bin/env bash
set -euo pipefail

DEFAULT="linux-arm32,linux-powerpc64-be,linux-x64,linux-arm64,windows-x64,macos-arm64,macos-x64,freebsd,solaris"

if [ -z "${INPUT_TARGETS// /}" ]; then
  TARGETS="$DEFAULT"
  SOURCE="default"
else
  TARGETS="${INPUT_TARGETS// /}"
  SOURCE="workflow_dispatch input"
fi

echo "enabled_targets=${TARGETS}" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
echo "::notice::Enabled targets (${SOURCE}): ${TARGETS}"
