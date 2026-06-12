#!/usr/bin/env bash
# TEMP(dragonfly-diagnostics): root-cause capture for the HTTPS download
# failure (ESocketError: Connect to github.com:443 failed). Best-effort and
# NON-FATAL — every probe is guarded so this never aborts the job; the normal
# build runs afterwards and reproduces the real error in the same log.
# Remove this script (and its call in make.yml) once the cause is confirmed.
#
# Round 2: curl-independent. curl is not installed in the VM (pkg drops it), so
# probe with tools that are always present: bash /dev/tcp (raw TCP), the dports
# OpenSSL the FPC shim points at (s_client), and base fetch (base LibreSSL).

# Deliberately no `set -e`: a failing probe must not stop the others.
set +e

# Mirror the build's runtime library path (matches the failing download's env).
export LD_LIBRARY_PATH="/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

GITHUB_URL="https://github.com/Xor-el/HashLib4Pascal/archive/master.zip"
OPM_URL="https://packages.lazarus-ide.org/HashLib.zip"

section() { printf '\n==================== %s ====================\n' "$1"; }
run()     { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }

# No timeout(1) in the BSD base, so roll our own: run "$@" in the background and
# hard-kill it after SECS so a blackholed connect can't hang the job.
with_timeout() {
  local secs="$1"; shift
  "$@" &
  local p=$!
  ( sleep "$secs"; kill -9 "$p" 2>/dev/null ) &
  local k=$!
  wait "$p" 2>/dev/null
  local rc=$?
  kill "$k" 2>/dev/null
  return "$rc"
}

section "uname / environment"
run uname -a
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"

section "resolver config (/etc/resolv.conf, /etc/hosts)"
run cat /etc/resolv.conf
run cat /etc/hosts

section "DNS resolution (drill)"
for h in github.com codeload.github.com packages.lazarus-ide.org; do
  run drill "$h"
done

section "raw TCP connect (no DNS, no TLS) via /dev/tcp"
for addr in 140.82.114.4:443 140.82.114.9:443; do
  ip="${addr%%:*}"; port="${addr##*:}"
  if with_timeout 20 bash -c "exec 3<>/dev/tcp/$ip/$port"; then
    echo "TCP $addr OK"
  else
    echo "TCP $addr FAILED (rc=$?)"
  fi
done

section "TLS handshake via dports OpenSSL (the lib FPC's shim points at)"
for host in github.com packages.lazarus-ide.org; do
  printf '$ openssl s_client -connect %s:443 -servername %s\n' "$host" "$host"
  printf '' | with_timeout 25 /usr/local/bin/openssl s_client \
    -connect "$host:443" -servername "$host" 2>&1 | sed -n '1,30p'
  printf '[done %s]\n' "$host"
done

section "HTTPS via base fetch (base LibreSSL)"
for url in "$GITHUB_URL" "$OPM_URL"; do
  printf '$ fetch -vo /dev/null %s\n' "$url"
  with_timeout 90 fetch -vo /dev/null "$url" 2>&1 | sed -n '1,40p'
  printf '[done %s]\n' "$url"
done

section "OpenSSL / shim state"
run sh -c 'openssl version 2>&1 || true'
run sh -c '/usr/local/bin/openssl version 2>&1 || true'
run ls -l /usr/local/lib/libssl.so.1.1 /usr/local/lib/libcrypto.so.1.1
run ls -l /usr/local/lib/libssl.so.* /usr/local/lib/libcrypto.so.*
run readlink -f /usr/local/lib/libssl.so.1.1
run readlink -f /usr/local/lib/libcrypto.so.1.1

section "downloader availability"
for tool in curl wget fetch git; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "$tool: $(command -v "$tool")"
  else
    echo "$tool: MISSING"
  fi
done

section "diagnostics complete"
exit 0
