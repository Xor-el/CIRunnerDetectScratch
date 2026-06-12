#!/bin/sh
set -eu

# Runs under the VM's /bin/sh, so resolve CI_ROOT from $0 rather than sourcing
# common.sh (which targets bash, e.g. BASH_SOURCE / set -o pipefail).
CI_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Reconcile the cached image with the current Avalon repo first: a single mixed
# install+upgrade+conflict transaction on a stale image makes pkg's SAT solver
# drop packages (curl, git-lite) instead of upgrading them. Upgrading first keeps
# installing full git + curl a small, resolvable step.
pkg update -f
pkg upgrade -y
pkg install -y bash curl git gmake openssl

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
