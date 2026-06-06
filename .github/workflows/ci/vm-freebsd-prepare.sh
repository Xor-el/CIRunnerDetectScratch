#!/usr/bin/env bash
# FreeBSD VM prepare — see FREEBSD_INSTALL_MODE (interim|preferred).
set -euo pipefail

: "${FREEBSD_INSTALL_MODE:?FREEBSD_INSTALL_MODE is required (interim|preferred)}"

if [ "$FREEBSD_INSTALL_MODE" = "preferred" ]; then
  export ASSUME_ALWAYS_YES=yes
  export IGNORE_OSVERSION=yes
  pkg bootstrap -f
  pkg upgrade -Fqy || true
  pkg update -f
  pkg upgrade -y
  pkg install -y bash curl git gmake binutils
  exit 0
fi

# INTERIM: pkg-installed FPC until FPC 3.2.4 dist tarball works on FreeBSD 15+.
export ASSUME_ALWAYS_YES=yes
export IGNORE_OSVERSION=yes
pkg bootstrap -f
pkg upgrade -Fqy || true
pkg update -f
pkg upgrade -y
pkg install -y fpc git wget gmake

LAZARUS_DIR="$HOME/lazarus-src"
git clone --depth 1 --branch "$LAZARUS_BRANCH" "$LAZARUS_REPO" "$LAZARUS_DIR"
gmake -C "$LAZARUS_DIR" lazbuild

mkdir -p "$HOME/.lazarus"
cat > "$HOME/.lazarus/environmentoptions.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<CONFIG>
  <EnvironmentOptions>
    <LazarusDirectory Value="$LAZARUS_DIR"/>
    <CompilerFilename Value="$(which fpc)"/>
  </EnvironmentOptions>
</CONFIG>
EOF

export PATH="$LAZARUS_DIR:$PATH"
lazbuild --version
