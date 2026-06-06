#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${FPC_VERSION:?FPC_VERSION is required}"
: "${FPC_TARGET:?FPC_TARGET is required}"
: "${MAKE_BUILD_BACKEND:?MAKE_BUILD_BACKEND is required}"

docker run --rm --platform linux/ppc64 \
  --security-opt seccomp=unconfined \
  -v "${GITHUB_WORKSPACE}:/work" -w /work \
  -e FPC_VERSION \
  -e FPC_TARGET \
  -e MAKE_BUILD_BACKEND \
  -e DEBIAN_FRONTEND=noninteractive \
  -e QEMU_CPU=power8 \
  urbanogilson/debian-debootstrap-ports:ppc64-forky-sid \
  bash .github/workflows/ci/ppc64-be-inner.sh
