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

ci_verify_toolchain() {
  fpc -iV
  if [ -n "${FPC_TARGET:-}" ]; then
    echo "::notice::FPC_TARGET=${FPC_TARGET}"
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
