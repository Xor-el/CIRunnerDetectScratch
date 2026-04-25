#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  Unified FPC + Lazarus installer for CI.
#
#  Fetches the FPC tarball from the official freepascal.org mirror,
#  runs install.sh non-interactively, then clones Lazarus and builds
#  lazbuild. Works on Linux, macOS, *BSD, Solaris, and Windows
#  (the latter via Git Bash, which ships pre-installed on
#  windows-latest GitHub runners).
#
#  All work happens under $HOME — no sudo, no system-level changes.
#
#  Inputs (env vars):
#    FPC_TARGET     e.g. x86_64-linux, aarch64-darwin, x86_64-win64
#    FPC_VERSION    FPC release version (default: 3.2.2)
#    INSTALL_PREFIX where FPC is installed (default: $HOME/fpc-install)
#    LAZARUS_DIR    where Lazarus source is cloned and built
#                   (default: $HOME/lazarus-src)
#    LAZARUS_BRANCH branch/tag to clone, e.g. lazarus_4_4
#    LAZARUS_REPO   git URL
#    MAKE_CMD       'make' on Linux/Windows/macOS, 'gmake' on BSD/Solaris
#                   (auto-detected if unset)
#
#  Outputs (appended to $GITHUB_PATH if set):
#    $INSTALL_PREFIX/bin and $LAZARUS_DIR are added to PATH
# ─────────────────────────────────────────────────────────────────────

set -xeuo pipefail

: "${FPC_VERSION:=3.2.2}"
: "${FPC_TARGET:?FPC_TARGET is required (e.g. x86_64-linux)}"
: "${LAZARUS_BRANCH:?LAZARUS_BRANCH is required}"
: "${LAZARUS_REPO:?LAZARUS_REPO is required}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)   IS_WINDOWS=1 ;;
  *)                      IS_WINDOWS=0 ;;
esac

: "${INSTALL_PREFIX:=$HOME/fpc-install}"
: "${LAZARUS_DIR:=$HOME/lazarus-src}"

# Pick GNU make. On most platforms 'make' is GNU make. On BSDs and
# Solaris, 'make' is BSD make and we need 'gmake'. On Windows
# (windows-latest runner) the only GNU make pre-installed is
# Strawberry Perl's 'gmake.exe' — there is no 'make' on PATH.
# Caller can override MAKE_CMD if they have a different setup.
if [ -z "${MAKE_CMD:-}" ]; then
  case "$(uname -s)" in
    *BSD|DragonFly|SunOS)        MAKE_CMD="gmake" ;;
    MINGW*|MSYS*|CYGWIN*)        MAKE_CMD="gmake" ;;
    *)                           MAKE_CMD="make"  ;;
  esac
fi

# ── Fetch + extract ──────────────────────────────────────────────────

# Some BSD tarballs have an OS-version suffix in the filename, e.g.
# fpc-3.2.2.x86_64-freebsd11.tar. The tarball extracts to a directory
# WITHOUT the version suffix. Map our canonical FPC_TARGET to the
# actual filename here; let the post-extract glob handle the directory
# name.
case "$FPC_TARGET" in
  x86_64-freebsd)   TAR_TARGET="x86_64-freebsd11" ;;
  *)                TAR_TARGET="$FPC_TARGET"      ;;
esac

TARBALL="fpc-${FPC_VERSION}.${TAR_TARGET}.tar"
URL="http://downloads.freepascal.org/fpc/dist/${FPC_VERSION}/${FPC_TARGET}/${TARBALL}"

WORK_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t fpc-install)"
cd "$WORK_DIR"

echo "Downloading $URL"
# curl is on every platform we target; wget isn't (macOS notably).
# Retry to ride out transient mirror hiccups.
curl -fL --retry 5 --retry-delay 5 --retry-all-errors \
  -o "$TARBALL" "$URL"

tar xf "$TARBALL"

# Glob the extracted directory: name varies (freebsd11 → freebsd).
# shellcheck disable=SC2086
set -- "fpc-${FPC_VERSION}".*
EXTRACT_DIR="$1"
cd "$EXTRACT_DIR"

# ── Run install.sh non-interactively ─────────────────────────────────
#
# The script asks (in order, each conditional on a file being present):
#   1. Install prefix                                  [always]
#   2. Install Cross binutils?            (Y/n)        [if binutils-*.tar.gz]
#   3. Install Textmode IDE?              (Y/n)        [if ide.<target>.tar.gz]
#   4. Install documentation?             (Y/n)        [if doc-pdf.tar.gz]
#   5. Install demos?                     (Y/n)        [if demo.tar.gz]
#   6. Install demos in <dir>             [path]       [only if 5 was Y]
#   7. Substitute version by $fpcversion? (Y/n)        [if fpc.cfg has version]
#
# We answer the prefix explicitly, then 'n' to everything optional.
# install.sh's yesno() treats empty input as YES, so if our answer
# stream runs short we'd silently install bundles we don't want.
# We send 10 'n's (more than the max number of yesno prompts) to
# guarantee every prompt gets an explicit 'n'. A bounded list is
# preferable to `yes n` — the latter receives SIGPIPE on consumer
# exit, which `set -o pipefail` would surface as a pipeline failure.
mkdir -p "$INSTALL_PREFIX"

# install.sh doesn't `set -e`, so it returns 0 even when its final
# samplecfg call fails (which it does on Windows — see below). We
# verify the install succeeded by checking for the compiler binary.
printf '%s\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\n' "$INSTALL_PREFIX" \
  | bash ./install.sh

# ── Locate the installed compiler ────────────────────────────────────
if [ "$IS_WINDOWS" = "1" ]; then
  FPC_EXE="$INSTALL_PREFIX/bin/fpc.exe"
else
  FPC_EXE="$INSTALL_PREFIX/bin/fpc"
fi

if [ ! -f "$FPC_EXE" ]; then
  echo "ERROR: FPC compiler not found at $FPC_EXE" >&2
  ls -la "$INSTALL_PREFIX/bin/" || true
  exit 1
fi

FPC_BIN_DIR="$(dirname "$FPC_EXE")"
export PATH="$FPC_BIN_DIR:$PATH"

# ── Windows-specific: generate fpc.cfg ───────────────────────────────
#
# install.sh's final step calls $LIBDIR/samplecfg, which is a POSIX
# shell script that does not ship in the Windows tarball. The Windows
# replacement is fpcmkcfg.exe, which IS shipped. Without an fpc.cfg,
# the compiler can't find its own units.
if [ "$IS_WINDOWS" = "1" ]; then
  FPCMKCFG="$INSTALL_PREFIX/bin/fpcmkcfg.exe"
  if [ ! -f "$FPCMKCFG" ]; then
    echo "ERROR: fpcmkcfg.exe not found at $FPCMKCFG" >&2
    exit 1
  fi
  "$FPCMKCFG" -d "basepath=$INSTALL_PREFIX/lib/fpc/$FPC_VERSION" \
              -o "$FPC_BIN_DIR/fpc.cfg"
fi

# Add to GitHub Actions PATH so subsequent steps see fpc.
# On Windows, GITHUB_PATH expects native Windows paths (C:\foo\bin),
# not MSYS/Git Bash paths (/c/foo/bin). cygpath converts both ways.
if [ -n "${GITHUB_PATH:-}" ]; then
  if [ "$IS_WINDOWS" = "1" ]; then
    cygpath -w "$FPC_BIN_DIR" >> "$GITHUB_PATH"
  else
    echo "$FPC_BIN_DIR" >> "$GITHUB_PATH"
  fi
fi

fpc -iV
fpc -iSO
fpc -iSP

# ── Build Lazarus from source ────────────────────────────────────────
#
# We always build lazbuild from source rather than using a packaged
# Lazarus. Reasons:
#   - Cross-platform consistency: same code path on all 10 targets.
#   - The packaged Lazarus on Linux/Windows pulls in the full IDE
#     (GTK / Qt / native widgets), which we don't need.
#   - lazbuild builds in ~1–2 minutes; cheap relative to the FPC fetch.

git clone --depth 1 --branch "$LAZARUS_BRANCH" "$LAZARUS_REPO" "$LAZARUS_DIR"

# DragonFlyBSD: Lazarus is missing include/dragonfly/lazconf.inc.
# DragonFlyBSD is a FreeBSD derivative, so the FreeBSD include works
# as-is. Patch it in before building.
if [ "$(uname -s)" = "DragonFly" ]; then
  DF_INC="$LAZARUS_DIR/ide/packages/ideconfig/include/dragonfly"
  if [ ! -f "$DF_INC/lazconf.inc" ]; then
    mkdir -p "$DF_INC"
    cp "$LAZARUS_DIR/ide/packages/ideconfig/include/freebsd/lazconf.inc" \
       "$DF_INC/lazconf.inc"
  fi
fi

# On Windows, gmake.exe is a native PE binary that may not understand
# Git Bash's /c/Users/... path style. Pass a Windows-format path.
if [ "$IS_WINDOWS" = "1" ]; then
  $MAKE_CMD -C "$(cygpath -w "$LAZARUS_DIR")" lazbuild
else
  $MAKE_CMD -C "$LAZARUS_DIR" lazbuild
fi

# ── Write Lazarus environmentoptions.xml ─────────────────────────────
# lazbuild reads this to locate the Lazarus source tree and the FPC
# compiler. Without it, lazbuild errors on first run.
#
# On Windows, lazbuild is a native PE binary that expects Windows-
# style paths in this XML. Convert MSYS paths if needed.
LAZ_CFG_DIR="${HOME}/.lazarus"
mkdir -p "$LAZ_CFG_DIR"

if [ "$IS_WINDOWS" = "1" ]; then
  LAZ_DIR_NATIVE="$(cygpath -w "$LAZARUS_DIR")"
  FPC_EXE_NATIVE="$(cygpath -w "$FPC_EXE")"
else
  LAZ_DIR_NATIVE="$LAZARUS_DIR"
  FPC_EXE_NATIVE="$FPC_EXE"
fi

cat > "$LAZ_CFG_DIR/environmentoptions.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<CONFIG>
  <EnvironmentOptions>
    <LazarusDirectory Value="$LAZ_DIR_NATIVE"/>
    <CompilerFilename Value="$FPC_EXE_NATIVE"/>
  </EnvironmentOptions>
</CONFIG>
EOF

# Put lazbuild on PATH for subsequent steps.
export PATH="$LAZARUS_DIR:$PATH"
if [ -n "${GITHUB_PATH:-}" ]; then
  if [ "$IS_WINDOWS" = "1" ]; then
    cygpath -w "$LAZARUS_DIR" >> "$GITHUB_PATH"
  else
    echo "$LAZARUS_DIR" >> "$GITHUB_PATH"
  fi
fi

lazbuild --version
echo "FPC + Lazarus installation complete."