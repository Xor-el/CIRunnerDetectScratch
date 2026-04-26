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
#
# Layout differs between Unix and Windows:
#   Unix:    $PREFIX/bin/fpc                    (single binary)
#   Windows: $PREFIX/bin/<target>/fpc.exe       (target-specific)
#            $PREFIX/bin/instantfpc.exe         (target-independent
#                                                 utilities)
# Both directories need to be on PATH on Windows.
if [ "$IS_WINDOWS" = "1" ]; then
  FPC_EXE="$INSTALL_PREFIX/bin/$FPC_TARGET/fpc.exe"
  FPC_UTIL_DIR="$INSTALL_PREFIX/bin"
else
  FPC_EXE="$INSTALL_PREFIX/bin/fpc"
  FPC_UTIL_DIR=""
fi

if [ ! -f "$FPC_EXE" ]; then
  echo "ERROR: FPC compiler not found at $FPC_EXE" >&2
  ls -la "$INSTALL_PREFIX/bin/" || true
  if [ "$IS_WINDOWS" = "1" ]; then
    ls -la "$INSTALL_PREFIX/bin/$FPC_TARGET/" || true
  fi
  exit 1
fi

FPC_BIN_DIR="$(dirname "$FPC_EXE")"
if [ -n "$FPC_UTIL_DIR" ]; then
  export PATH="$FPC_BIN_DIR:$FPC_UTIL_DIR:$PATH"
else
  export PATH="$FPC_BIN_DIR:$PATH"
fi

# ── Linux glibc 2.34+ workaround ─────────────────────────────────────
#
# FPC 3.2.2 was built against glibc < 2.34 and its cprt0.o references
# __libc_csu_init / __libc_csu_fini, which glibc 2.34 (Aug 2021) made
# private. Linking anything FPC produces against current glibc fails:
#   undefined reference to `__libc_csu_init'
#   undefined reference to `__libc_csu_fini'
#
# Ubuntu 22.04+ ships glibc 2.34+ and is affected. The fix shipped in
# FPC 3.2.4+ (and Debian/Fedora patched their packages); for our
# pre-built tarball we patch in place by merging stub object code
# into cprt0.o, satisfying the symbols at link time.
#
# Affected: every Linux target (x86_64, aarch64, arm/armhf). The
# 'cprt0' name is consistent across architectures.
#
# See https://gitlab.com/freepascal.org/fpc/source/-/issues/39295
if [ "$(uname -s)" = "Linux" ]; then
  RTL_DIR="$INSTALL_PREFIX/lib/fpc/$FPC_VERSION/units/$FPC_TARGET/rtl"
  CPRT0="$RTL_DIR/cprt0.o"
  if [ -f "$CPRT0" ]; then
    STUB_C="$WORK_DIR/csu_stubs.c"
    STUB_O="$WORK_DIR/csu_stubs.o"
    cat > "$STUB_C" <<'EOF'
/* glibc 2.34+ removed __libc_csu_init / __libc_csu_fini. FPC 3.2.2's
   cprt0.o still references them. Provide empty stubs so the linker
   is satisfied. */
void __libc_csu_init(int argc, char **argv, char **envp) { (void)argc; (void)argv; (void)envp; }
void __libc_csu_fini(void) {}
EOF
    cc -c -fPIC -o "$STUB_O" "$STUB_C"
    # Merge stubs into cprt0.o using `ld -r` (relocatable link).
    # cprt0.o references __libc_csu_*; the stub provides them; the
    # merged object resolves both within itself.
    ld -r -o "$CPRT0.new" "$CPRT0" "$STUB_O"
    mv "$CPRT0.new" "$CPRT0"
    echo "Patched $CPRT0 with glibc 2.34+ stubs."
  fi
fi

# ── FreeBSD: rebuild from source against the host libc ──────────────
#
# The FPC tarball at downloads.freepascal.org for FreeBSD is named
# fpc-3.2.2.x86_64-freebsd11.tar — meaning it was built on FreeBSD 11.
# FreeBSD's ABI is not stable across major versions: binaries linking
# against the FreeBSD 11 RTL units segfault at startup on FreeBSD 13+
# (whereas the bootstrap compiler itself happens to run, because it
# only uses a small subset of libc that hasn't shifted).
#
# The compat11x/12x/13x ports that historically smoothed this over
# are no longer in pkg repositories on FreeBSD 14.x.
#
# So we use the freshly-installed compiler as a stage-1 bootstrap to
# rebuild FPC from source against the RUNNING FreeBSD's libc. The
# stage-2 install replaces stage-1 in place. This is what every
# distro's FPC package does internally, just done locally per-CI run.
# It adds ~5 minutes to the FreeBSD job but is the only known fix
# that works across FreeBSD 13/14/15.
#
# After bootstrap, every FPC-built binary (including lazbuild)
# correctly links against the host's libc.so.7 and runs.
if [ "$(uname -s)" = "FreeBSD" ]; then
  echo "Bootstrapping FPC from source for native FreeBSD compatibility..."

  # Move the freebsd11-built install aside; we'll use its compiler
  # as the bootstrap and then replace the whole tree.
  STAGE1_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t fpc-stage1)"
  rmdir "$STAGE1_DIR"
  mv "$INSTALL_PREFIX" "$STAGE1_DIR"
  mkdir -p "$INSTALL_PREFIX"

  # The FPC Makefile expects FPC= to point at the architecture-
  # specific compiler binary (ppcx64 for x86_64), NOT the 'fpc'
  # wrapper script. Passing the wrapper makes the Makefile fail to
  # parse the target triple and emit nonsense like
  #   "OS_TARGET=be CPU_TARGET=ppcx64 ... target ppcx64-be"
  STAGE1_PPCX64="$STAGE1_DIR/lib/fpc/$FPC_VERSION/ppcx64"
  if [ ! -x "$STAGE1_PPCX64" ]; then
    echo "ERROR: stage-1 ppcx64 not at $STAGE1_PPCX64" >&2
    ls -la "$STAGE1_DIR/lib/fpc/$FPC_VERSION/" || true
    exit 1
  fi

  # Clone FPC source. We use fixes_3_2 instead of the release_3_2_2
  # tag because FPC 3.2.2's source has a known FreeBSD ≥12
  # incompatibility: FreeBSD 12 introduced a new struct stat layout
  # (64-bit inode numbers, link counts, field reorderings) and the
  # Pascal binding in 3.2.2 still uses the FreeBSD 11 layout. Any
  # RTL function that uses stat() (FileExists, sysutils, fpmake,
  # lazbuild, ...) reads garbage and segfaults. fixes_3_2 is the
  # post-release maintenance branch where backports of FreeBSD
  # compatibility patches accumulate; rebuilding from this branch
  # gives us up-to-date struct definitions while keeping us on the
  # 3.2.x line. See FPC issue #37784.
  FPC_SRC_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t fpc-source)"
  git clone --depth 1 --branch fixes_3_2 \
    https://gitlab.com/freepascal.org/fpc/source.git "$FPC_SRC_DIR"

  # Build using stage-1 ppcx64 as bootstrap, target = host.
  $MAKE_CMD -C "$FPC_SRC_DIR" all \
    FPC="$STAGE1_PPCX64" \
    OS_TARGET=freebsd \
    CPU_TARGET=x86_64

  # Install stage-2 over the (now empty) install prefix. Use the
  # freshly-built compiler at compiler/ppcx64 — that's what the FPC
  # build wiki recommends (the source-tree compiler, not stage-1) so
  # the installed RTL etc. match what we just produced.
  $MAKE_CMD -C "$FPC_SRC_DIR" install \
    FPC="$FPC_SRC_DIR/compiler/ppcx64" \
    OS_TARGET=freebsd \
    CPU_TARGET=x86_64 \
    INSTALL_PREFIX="$INSTALL_PREFIX"

  # The install creates $PREFIX/lib/fpc/<ver>/ but doesn't itself
  # generate fpc.cfg; we run samplecfg explicitly the same way
  # install.sh would have.
  if [ -x "$INSTALL_PREFIX/lib/fpc/$FPC_VERSION/samplecfg" ]; then
    "$INSTALL_PREFIX/lib/fpc/$FPC_VERSION/samplecfg" \
      "$INSTALL_PREFIX/lib/fpc/$FPC_VERSION"
  fi

  # Drop stage-1 — we don't need it anymore.
  rm -rf "$STAGE1_DIR" "$FPC_SRC_DIR"

  echo "FreeBSD bootstrap complete. Rebuilt FPC linked against host libc."
fi

# ── Windows-specific: generate fpc.cfg ───────────────────────────────
#
# install.sh's final step calls $LIBDIR/samplecfg, which is a POSIX
# shell script that does not ship in the Windows tarball. The Windows
# replacement is fpcmkcfg.exe at $PREFIX/bin/. Without an fpc.cfg,
# the compiler can't find its own units. Note: fpc.cfg goes next to
# fpc.exe in $PREFIX/bin/<target>/, since FPC searches there first.
if [ "$IS_WINDOWS" = "1" ]; then
  FPCMKCFG="$FPC_UTIL_DIR/fpcmkcfg.exe"
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
# Both bin/<target> and bin/ go on PATH so subsequent steps find both
# fpc.exe (the compiler) and instantfpc.exe (the utility).
if [ -n "${GITHUB_PATH:-}" ]; then
  if [ "$IS_WINDOWS" = "1" ]; then
    cygpath -w "$FPC_BIN_DIR"  >> "$GITHUB_PATH"
    cygpath -w "$FPC_UTIL_DIR" >> "$GITHUB_PATH"
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
# lazbuild reads this on startup to locate the Lazarus source tree
# and the FPC compiler. Without it, lazbuild emits:
#   Error: (lazbuild) Invalid Lazarus directory "": directory lcl not found
#
# The location lazbuild looks at is platform-specific:
#   Unix:    $HOME/.lazarus/                                      (dotted)
#   Windows: %LOCALAPPDATA%\lazarus\           — NOT %APPDATA%, NOT dotted
#
# The Windows path comes from Lazarus's lazbaseconf.inc:
#   PrimaryConfigPath := ExtractFilePath(ChompPathDelim(
#                          GetAppConfigDirUTF8(False))) + 'lazarus';
# where GetAppConfigDir(False) on Windows resolves via
# CSIDL_LOCAL_APPDATA to %LOCALAPPDATA%\<appname>\, so the parent +
# 'lazarus' is %LOCALAPPDATA%\lazarus\ (no leading dot).
#
# On Windows, lazbuild is a native PE binary and expects Windows-
# style paths in the XML values, so we cygpath them to backslash form.
if [ "$IS_WINDOWS" = "1" ]; then
  # On Windows runners $LOCALAPPDATA is set; fall back to the
  # well-known location if it isn't.
  WIN_LOCALAPPDATA="${LOCALAPPDATA:-$USERPROFILE/AppData/Local}"
  LAZ_CFG_DIR="$(cygpath -u "$WIN_LOCALAPPDATA")/lazarus"
  LAZ_DIR_NATIVE="$(cygpath -w "$LAZARUS_DIR")"
  FPC_EXE_NATIVE="$(cygpath -w "$FPC_EXE")"
else
  LAZ_CFG_DIR="${HOME}/.lazarus"
  LAZ_DIR_NATIVE="$LAZARUS_DIR"
  FPC_EXE_NATIVE="$FPC_EXE"
fi

mkdir -p "$LAZ_CFG_DIR"

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