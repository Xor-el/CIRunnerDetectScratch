#!/bin/sh
set -eu

# Runs under the VM's /bin/sh, so resolve CI_ROOT from $0 rather than sourcing
# common.sh (which targets bash, e.g. BASH_SOURCE / set -o pipefail).
CI_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Refresh the catalogue (this also pulls a newer pkg if the cached image ships an
# old one). Deliberately NO blanket `pkg upgrade`: on this stale image pkg 2.x's
# SAT solver can't reconcile all ~43 upgrade candidates and "resolves" the
# conflict by DROPPING packages we need — curl, git-lite and friends get removed
# and never reinstalled (observed in CI). Instead install each build dependency
# in its own small transaction the solver can actually satisfy.
pkg update -f

# bash is mandatory: the VM 'run' step is `bash ...`. Keep it strict.
pkg install -y bash

# Best-effort extras. The build no longer depends on any single one of these
# (make.pas falls back to fetch for downloads and the base image already ships
# openssl), so a solver miss must warn, not abort the whole job.
for p in gmake openssl curl; do
  pkg install -y "$p" || echo "WARN(dragonfly-prepare): could not install $p; continuing"
done

# Prefer full git over the base image's git-lite (git-lite omits features that
# lazbuild/tooling may want later). pkg swaps the conflicting git-lite out as
# part of installing git; best-effort so a solver miss leaves git-lite in place.
if pkg install -y git; then
  pkg remove -y git-lite git-litem 2>/dev/null || true
else
  echo "WARN(dragonfly-prepare): could not install full git; keeping git-lite if present"
fi

# vmactions copies artifacts back out of the VM with rsync. The openssl upgrade
# above triggers an ABI cleanup that removes the base rsync (it was linked
# against the old openssl), so reinstall it or the job fails at the final
# "Copyback artifacts" step with "rsync: not found". Strict: the job cannot
# succeed without it, so surface a failure here rather than at copyback.
pkg install -y rsync

# TODO(FPC 3.2.4): drop the OpenSSL 1.1 shim once FPC links against OpenSSL 3.
OPENSSL_USE_SUDO=0 bash "$CI_ROOT/openssl-libssl11-shim-unix.sh" /usr/local/lib
