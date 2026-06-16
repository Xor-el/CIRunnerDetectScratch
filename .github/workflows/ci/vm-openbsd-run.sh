#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=shared/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shared/common.sh"
ci_init_paths

: "${OPENBSD_INSTALL_MODE:?OPENBSD_INSTALL_MODE is required (interim|preferred)}"

if [ "$OPENBSD_INSTALL_MODE" = "preferred" ]; then
  # Tarball path (see vm-openbsd-prepare.sh): currently only works on an OpenBSD
  # release matching the dist tarball's build host. Kept for parity/future.
  ci_build_standard
else
  # Interim: the toolchain is pkg-installed in prepare (fpc at /usr/local/bin,
  # already on PATH), so build against it directly without running the installer.
  #
  # lazarus-src exists only when the lazbuild backend built it in prepare; the
  # pkg-installed fpc is already on PATH, so only prepend it when present.
  if [ -d "$HOME/lazarus-src" ]; then
    export PATH="$HOME/lazarus-src:$PATH"
  fi
  ci_build_prebuilt
fi
