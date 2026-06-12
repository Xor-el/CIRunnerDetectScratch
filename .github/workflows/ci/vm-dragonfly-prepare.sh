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

# DragonFly's FPC 3.2.2 fcl-net resolver can't query this VM's DNS (the QEMU NAT
# nameserver), so TFPHttpClient dies with "Host name resolution for ... failed"
# even though the system resolver works fine (drill/fetch/openssl all resolve and
# download). netdb consults /etc/hosts before DNS, so pre-resolve the download
# hosts with drill and pin them. codeload.github.com and objects.githubusercontent.com
# are GitHub's redirect targets for archive/release downloads — pin them too, or the
# resolver fails again after the 302. Best-effort: a lookup miss leaves a host
# unpinned rather than failing the job.
# Match the first real A record: skip drill's comment/question lines ($1 starting
# with ';' — the QUESTION line "github.com. IN A" also has $4=="A" but no address),
# and skip CNAME lines (e.g. packages.lazarus-ide.org -> www.lazarus-ide.org) so the
# pinned value is an IP, not the CNAME target.
for h in github.com codeload.github.com objects.githubusercontent.com \
         packages.lazarus-ide.org downloads.freepascal.org; do
  ip=$(drill "$h" 2>/dev/null | awk '$1 !~ /^;/ && $4 == "A" { print $5; exit }')
  if [ -n "$ip" ]; then
    echo "$ip $h" >> /etc/hosts
  fi
done

# TODO(FPC 3.2.4): drop the OpenSSL 1.1 shim once FPC links against OpenSSL 3.
OPENSSL_USE_SUDO=0 bash "$CI_ROOT/openssl-libssl11-shim-unix.sh" /usr/local/lib
