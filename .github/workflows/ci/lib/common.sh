#!/usr/bin/env bash
# Shared CI helpers — source from scripts under .github/workflows/ci/

set -euo pipefail

ci_init_paths() {
  CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  WORKFLOWS_DIR="$(cd "$CI_ROOT/.." && pwd)"
  REPO_ROOT="$(cd "$WORKFLOWS_DIR/../.." && pwd)"
}

ci_install_toolchain() {
  : "${FPC_TARGET:?FPC_TARGET is required}"
  bash "$WORKFLOWS_DIR/install-fpc-lazarus.sh"
}

ci_export_toolchain_path() {
  local prefix="${INSTALL_PREFIX:-$HOME/fpc-install}"
  export PATH="${LAZARUS_DIR:-$HOME/lazarus-src}:$prefix/bin:${PATH}"
  if [ -n "${FPC_TARGET:-}" ] && [ -d "$prefix/bin/$FPC_TARGET" ]; then
    export PATH="$prefix/bin/$FPC_TARGET:$PATH"
  fi
}

ci_runtime_byteorder() {
  # Reliable process endian probe (lscpu often lies under QEMU user-mode).
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}.c" <<'EOF'
#include <stdio.h>
int main(void) {
  int x = 1;
  return *(const char *)&x;
}
EOF
  if cc -o "${tmp}" "${tmp}.c" 2>/dev/null; then
    if "${tmp}"; then
      echo "little"
    else
      echo "big"
    fi
  else
    echo "unknown"
  fi
  rm -f "${tmp}" "${tmp}.c"
}

ci_elf_endian() {
  # ELF e_ident[EI_DATA] byte 5: 1=LE, 2=BE. Empty if not ELF.
  local path="$1" data
  [ -f "$path" ] || return 1
  data="$(od -An -j 5 -N 1 -t u1 "$path" 2>/dev/null | tr -d ' ')"
  case "$data" in
    1) echo "little" ;;
    2) echo "big" ;;
    *) echo "unknown" ;;
  esac
}

ci_assert_powerpc64_be() {
  [ "${FPC_TARGET:-}" = "powerpc64-linux" ] || return 0

  local machine byteorder backend elfinfo
  machine="$(uname -m)"
  echo "::notice::kernel $(uname -s) ${machine}"

  if [ "$machine" = "ppc64le" ]; then
    echo "::error::powerpc64-linux BE CI requires uname -m ppc64, got ppc64le" >&2
    exit 1
  fi
  if [ "$machine" != "ppc64" ]; then
    echo "::warning::unexpected uname -m ${machine} for powerpc64-linux" >&2
  fi

  byteorder="$(ci_runtime_byteorder)"
  echo "::notice::runtime byteorder: ${byteorder}"
  if [ "$byteorder" = "little" ]; then
    echo "::error::powerpc64-linux BE CI but runtime byteorder is little" >&2
    exit 1
  fi

  if [ -f /bin/bash ]; then
    echo "::notice::/bin/bash ELF endian: $(ci_elf_endian /bin/bash)"
    if [ "$(ci_elf_endian /bin/bash)" = "little" ]; then
      echo "::error::userspace /bin/bash is little-endian ELF; expected BE for ppc64" >&2
      exit 1
    fi
  fi

  backend="${INSTALL_PREFIX:-$HOME/fpc-install}/bin/ppcppc64"
  if [ -f "$backend" ]; then
    echo "::notice::ppcppc64 ELF endian: $(ci_elf_endian "$backend")"
    if [ "$(ci_elf_endian "$backend")" = "little" ]; then
      echo "::error::ppcppc64 is little-endian ELF; expected BE for powerpc64-linux" >&2
      exit 1
    fi
  fi

  if command -v lscpu >/dev/null 2>&1; then
    lscpu 2>/dev/null | grep -i 'byte order' \
      | sed 's/^/::notice::lscpu (often wrong under QEMU; trust runtime byteorder): /' \
      || true
  fi
}

ci_verify_toolchain() {
  fpc -iV
  if [ -n "${FPC_TARGET:-}" ]; then
    echo "::notice::FPC_TARGET=${FPC_TARGET}"
    echo "::notice::fpc -iTO $(fpc -iTO 2>/dev/null || echo n/a)"
  fi
  ci_assert_powerpc64_be
  if [ "${FPC_TARGET:-}" != "powerpc64-linux" ]; then
    echo "::notice::kernel $(uname -s) $(uname -m)"
    if command -v lscpu >/dev/null 2>&1; then
      lscpu 2>/dev/null | grep -i 'byte order' | head -1 | sed 's/^/::notice::/' || true
    fi
  fi
  if command -v lazbuild >/dev/null 2>&1; then
    lazbuild --version
  fi
}

ci_run_make() {
  instantfpc "$WORKFLOWS_DIR/make.pas"
}

ci_build_standard() {
  ci_install_toolchain
  ci_export_toolchain_path
  ci_verify_toolchain
  ci_run_make
}

ci_openssl_hack() {
  case "$(uname -s)" in
    Linux)  bash "$CI_ROOT/openssl-linux.sh" ;;
    Darwin) bash "$CI_ROOT/openssl-macos.sh" ;;
  esac
}
