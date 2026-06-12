#!/usr/bin/env bash
# TEMP(dragonfly-diagnostics): root-cause capture for the HTTPS download
# failure (ESocketError: Connect to github.com:443 failed). Best-effort and
# NON-FATAL — every probe is guarded so this never aborts the job; the normal
# build runs afterwards and reproduces the real error in the same log.
# Remove this script (and its call in make.yml) once the cause is confirmed.

# Deliberately no `set -e`: a failing probe must not stop the others.
set +e

# Mirror the build's runtime library path so the fpc repro loads the same
# (shimmed dports) OpenSSL the failing download uses.
export LD_LIBRARY_PATH="/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

GITHUB_URL="https://github.com/Xor-el/HashLib4Pascal/archive/master.zip"
OPM_URL="https://packages.lazarus-ide.org/HashLib.zip"

section() { printf '\n==================== %s ====================\n' "$1"; }
run()     { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }

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

section "curl: full download attempt (follow redirects)"
for url in "$GITHUB_URL" "$OPM_URL"; do
  run curl -sSL -o /dev/null \
    -w 'http=%{http_code} ip=%{remote_ip} redirects=%{num_redirects} time=%{time_total}s final=%{url_effective}\n' \
    --connect-timeout 20 --max-time 120 \
    -A 'Mozilla/5.0 (compatible; fpweb)' "$url"
done

section "curl: verbose TLS handshake (github.com, packages.lazarus-ide.org)"
for host in "https://github.com" "https://packages.lazarus-ide.org"; do
  printf '$ curl -sSv -o /dev/null %s\n' "$host"
  curl -sSv -o /dev/null --connect-timeout 20 --max-time 60 "$host" 2>&1 | sed -n '1,40p'
  printf '[done %s]\n' "$host"
done

section "OpenSSL / shim state"
run sh -c 'openssl version 2>&1 || true'
run sh -c '/usr/local/bin/openssl version 2>&1 || true'
run ls -l /usr/local/lib/libssl.so.1.1 /usr/local/lib/libcrypto.so.1.1
run ls -l /usr/local/lib/libssl.so.* /usr/local/lib/libcrypto.so.*
run readlink -f /usr/local/lib/libssl.so.1.1
run readlink -f /usr/local/lib/libcrypto.so.1.1
run sh -c 'ldd "$(command -v curl)" 2>&1 | grep -i ssl'

section "FPC repro: InitSSLInterface + TFPHttpClient.Get (same env as build)"
if command -v fpc >/dev/null 2>&1; then
  probe_dir="$(mktemp -d 2>/dev/null || mktemp -d -t ssl-probe)"
  cat > "$probe_dir/sslprobe.pas" <<'PAS'
program SslProbe;
{$mode objfpc}{$H+}
uses SysUtils, Classes, fphttpclient, openssl, opensslsockets;
var
  C: TFPHttpClient;
  S: TMemoryStream;
begin
  if not InitSSLInterface then
  begin
    Writeln('PROBE: InitSSLInterface returned FALSE');
    Halt(2);
  end;
  Writeln('PROBE: InitSSLInterface OK (libssl handle loaded)');
  S := TMemoryStream.Create;
  C := TFPHttpClient.Create(nil);
  try
    C.AddHeader('User-Agent', 'Mozilla/5.0 (compatible; fpweb)');
    C.AllowRedirect := True;
    try
      C.Get(ParamStr(1), S);
      Writeln(Format('PROBE: GET OK status=%d bytes=%d', [C.ResponseStatusCode, S.Size]));
    except
      on E: Exception do
        Writeln(Format('PROBE: GET FAILED %s: %s', [E.ClassName, E.Message]));
    end;
  finally
    C.Free;
    S.Free;
  end;
end.
PAS
  if fpc -FE"$probe_dir" -FU"$probe_dir" -osslprobe "$probe_dir/sslprobe.pas" >"$probe_dir/build.log" 2>&1; then
    for url in "$GITHUB_URL" "$OPM_URL"; do
      run "$probe_dir/sslprobe" "$url"
    done
  else
    echo "PROBE: failed to compile sslprobe.pas"
    sed -n '1,40p' "$probe_dir/build.log"
  fi
  rm -rf "$probe_dir"
else
  echo "PROBE: fpc not on PATH; skipping"
fi

section "diagnostics complete"
exit 0
