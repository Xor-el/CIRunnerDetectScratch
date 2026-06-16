#!/bin/sh
# OpenBSD VM prepare — see OPENBSD_INSTALL_MODE (interim|preferred).
# Invoked with /bin/sh (bash is installed by this script; the run step is bash).
# pkg_add reads the mirror from /etc/installurl (baked into the image), so no
# PKG_PATH is needed.
set -eu

: "${OPENBSD_INSTALL_MODE:?OPENBSD_INSTALL_MODE is required (interim|preferred)}"

CI_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/common.sh
. "$CI_ROOT/shared/common.sh"

if [ "$OPENBSD_INSTALL_MODE" = "preferred" ]; then
  # Tarball path: ci_build_standard downloads/extracts the official dist.
  #   curl  - ci_download's fetcher (OpenBSD base ships neither curl nor `fetch`)
  #   gmake - ci_default_make_cmd maps *BSD -> gmake
  #   rsync - vmactions copies the workspace back out via rsync at job end
  # NOTE: the official FPC 3.2.2 x86_64-openbsd tarball is built on OpenBSD 6.8
  # and dynamically linked to that release's library sonames; OpenBSD has no
  # cross-release binary compatibility, so this mode only works on a matching
  # old release (or a future tarball). The default mode is interim.
  pkg_add bash curl git gmake rsync
  exit 0
fi

# Interim (default): use the ABI-matched ports compiler instead of the dist
# tarball. The official FPC 3.2.2 OpenBSD tarball is built on OpenBSD 6.8 and
# dynamically linked to that release's exact library sonames (e.g. libc.so.96.0,
# libpthread.so.26.1). OpenBSD provides no cross-release binary compatibility,
# so it can't run on the VM's current release. Build against pkg fpc instead
# (see vm-openbsd-run.sh).
#   fpc   - the ports compiler (lang/fpc 3.2.2), ABI-matched to this release
#   git   - clone Lazarus when MAKE_BUILD_BACKEND=lazbuild
#   gmake - ci_default_make_cmd maps *BSD -> gmake
#   rsync - vmactions copies the workspace back out via rsync at job end
pkg_add bash git gmake rsync fpc

# Only build Lazarus/lazbuild when the lazbuild backend needs it. With the fpc
# backend make.pas never invokes lazbuild, so skip the clone+build (mirrors the
# FreeBSD interim path and install-fpc-lazarus.sh, which gate Lazarus the same way).
if [ "${MAKE_BUILD_BACKEND:-fpc}" = "lazbuild" ]; then
  export FPC_EXE="$(which fpc)"
  export LAZARUS_DIR="$HOME/lazarus-src"
  # shellcheck source=shared/lazarus-bootstrap.sh
  . "$CI_ROOT/shared/lazarus-bootstrap.sh"
else
  echo "MAKE_BUILD_BACKEND=fpc - interim mode: pkg fpc only, skipping Lazarus/lazbuild build"
fi
