#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${FPC_VERSION:?FPC_VERSION is required}"
: "${FPC_TARGET:?FPC_TARGET is required}"
: "${MAKE_BUILD_BACKEND:?MAKE_BUILD_BACKEND is required}"

CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_SHARED="$CI_ROOT/shared"
# shellcheck source=ppc64-be-images.env
source "$CI_ROOT/ppc64-be-images.env"
DOCKER_DIR="$CI_ROOT/docker/ppc64-be"

# Cross-compile glibc csu stubs on the x86 host. gcc inside QEMU ppc64
# user-mode often SIGSEGVs; install-fpc-lazarus.sh expects CSU_STUBS_PREBUILT.
STUB_C="$(mktemp --suffix=.c)"
STUB_OBJ="$(mktemp --suffix=.o)"
CSU_STUBS_IN_CONTAINER=/csu_stubs_prebuilt.o
trap 'rm -f "$STUB_C" "$STUB_OBJ"' EXIT

cp "$CI_SHARED/csu-stubs.c" "$STUB_C"

sudo apt-get update -qq
sudo apt-get install -y -qq gcc-powerpc64-linux-gnu
powerpc64-linux-gnu-gcc -c -fPIC -o "$STUB_OBJ" "$STUB_C"
if [ ! -s "$STUB_OBJ" ]; then
  echo "::error::cross-compile did not produce csu stubs object at $STUB_OBJ" >&2
  exit 1
fi
echo "csu stubs cross-compiled: $(wc -c < "$STUB_OBJ") bytes"

echo "Building ppc64 BE CI image ($PPC64_CI_IMAGE) with embedded QEMU..."
docker build \
  --platform linux/ppc64 \
  -f "$DOCKER_DIR/Dockerfile" \
  --build-arg "QEMU_IMAGE=$PPC64_QEMU_IMAGE" \
  --build-arg "BASE_IMAGE=$PPC64_BASE_IMAGE" \
  -t "$PPC64_CI_IMAGE" \
  "$DOCKER_DIR"

echo "Smoke test: qemu binaries and uname inside $PPC64_CI_IMAGE..."
docker run --rm --platform linux/ppc64 \
  --security-opt seccomp=unconfined \
  "$PPC64_CI_IMAGE" \
  bash -c 'test -x /usr/bin/qemu-ppc64-static && test -x /usr/bin/qemu-ppc64 && uname -m' | tee /tmp/ppc64-smoke-uname.txt
if ! grep -qx 'ppc64' /tmp/ppc64-smoke-uname.txt; then
  echo "::error::ppc64 smoke test: expected uname -m == ppc64" >&2
  exit 1
fi

docker run --rm --platform linux/ppc64 \
  --security-opt seccomp=unconfined \
  -v "${GITHUB_WORKSPACE}:/work" -w /work \
  -v "${STUB_OBJ}:${CSU_STUBS_IN_CONTAINER}:ro" \
  -e FPC_VERSION \
  -e FPC_TARGET \
  -e MAKE_BUILD_BACKEND \
  -e DEBIAN_FRONTEND=noninteractive \
  -e QEMU_CPU=power8 \
  -e CSU_STUBS_PREBUILT="${CSU_STUBS_IN_CONTAINER}" \
  "$PPC64_CI_IMAGE" \
  bash .github/workflows/ci/ppc64-be-inner.sh
