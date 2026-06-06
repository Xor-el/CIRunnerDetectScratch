#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${FPC_VERSION:?FPC_VERSION is required}"
: "${FPC_TARGET:?FPC_TARGET is required}"
: "${MAKE_BUILD_BACKEND:?MAKE_BUILD_BACKEND is required}"

# Cross-compile glibc csu stubs on the x86 host. gcc inside QEMU ppc64
# user-mode often SIGSEGVs; install-fpc-lazarus.sh expects CSU_STUBS_PREBUILT.
STUB_C="$(mktemp)"
STUB_OBJ="${GITHUB_WORKSPACE}/.github/workflows/ci/.csu_stubs.powerpc64-linux.o"
trap 'rm -f "$STUB_C"' EXIT

cat > "$STUB_C" <<'EOF'
/* glibc 2.34+ removed __libc_csu_init / __libc_csu_fini. FPC 3.2.2's
   RTL still references them. Provide empty stubs so the linker
   is satisfied. */
void __libc_csu_init(int argc, char **argv, char **envp) { (void)argc; (void)argv; (void)envp; }
void __libc_csu_fini(void) {}
EOF

sudo apt-get update -qq
sudo apt-get install -y -qq gcc-powerpc64-linux-gnu
powerpc64-linux-gnu-gcc -c -fPIC -o "$STUB_OBJ" "$STUB_C"

docker run --rm --platform linux/ppc64 \
  --security-opt seccomp=unconfined \
  -v "${GITHUB_WORKSPACE}:/work" -w /work \
  -e FPC_VERSION \
  -e FPC_TARGET \
  -e MAKE_BUILD_BACKEND \
  -e DEBIAN_FRONTEND=noninteractive \
  -e QEMU_CPU=power8 \
  -e CSU_STUBS_PREBUILT="/work/.github/workflows/ci/.csu_stubs.powerpc64-linux.o" \
  urbanogilson/debian-debootstrap-ports:ppc64-forky-sid \
  bash .github/workflows/ci/ppc64-be-inner.sh
