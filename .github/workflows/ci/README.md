# CI scripts (`make.yml` + `ci/`)

## Entry points

| Job | Script | Flow |
|-----|--------|------|
| linux-x64 / linux-arm64 / windows-x64 / macos-arm64 / macos-x64 | `native-build.sh` | `ci_openssl_hack` → `ci_build_standard` |
| linux-arm32 | `arm32-run.sh` → `arm32-install.sh` | Debian bootstrap + `ci_build_standard` |
| linux-powerpc64-be | `ppc64-qemu-setup.sh` → `ppc64-be-build.sh` → `ppc64-be-inner.sh` | Pinned host binfmt + urbanogilson full image |
| freebsd | `vm-freebsd-prepare.sh` + `vm-freebsd-run.sh` | `FREEBSD_INSTALL_MODE`: interim or preferred |
| netbsd / dragonfly / solaris | `vm-*-prepare.sh` + `vm-run-shared.sh` | `ci_build_standard` |

Shared helpers live in [`shared/common.sh`](shared/common.sh) (e.g. `ci_default_make_cmd`, `ci_is_windows`, `ci_build_standard`, `ci_build_prebuilt`). Build driver: [`../make.pas`](../make.pas) via `instantfpc`.

## Target selection (`targets.json` + `resolve-targets.sh`)

[`targets.json`](targets.json) is the single source of truth for every target (`id`, `name`, `kind` = `native`|`qemu`|`vm`, `default`, `runner`, `fpc_target`). `kind` is descriptive metadata (it no longer drives a matrix). To add a target, add an entry here **and** a standalone job in [`make.yml`](../make.yml) (each target — native, qemu, or vm — is its own `if:`-gated job). Set `default: false` to stop a target from running automatically (it stays runnable via `workflow_dispatch`).

[`resolve-targets.sh`](resolve-targets.sh) reads it via `jq` and emits two job outputs, both consumed by every standalone job:

- `enabled_targets` (CSV) — gates each job via its job-level `if: contains(...)`.
- `target_map` (JSON, id -> entry) — each job resolves its `runs-on` (`runner`) and `FPC_TARGET` (`fpc_target`) from this. It covers the whole registry so the lookup resolves even for an `if:`-skipped target. Job `name:` values stay literal in `make.yml` (a skipped job renders an unevaluated name expression in the UI).

**Default targets** (`default: true`, run on push/PR): `linux-x64`, `linux-arm64`, `windows-x64`, `macos-arm64`, `macos-x64`, `linux-arm32`, `linux-powerpc64-be`, `freebsd`, `solaris`.

**Opt-in targets** (`default: false`, workflow_dispatch only): `netbsd`, `dragonflybsd` — pass explicitly in `enabled_targets`. The `enabled_targets` input also lets you run any single target or exclude others.

## PowerPC64 big-endian flow

The runtime rootfs is [`ppc64-be-images.env`](ppc64-be-images.env) (`urbanogilson/debian-debootstrap-ports:ppc64-forky-sid`, full variant). Debian-ports ppc64 BE only exists in sid, so there is no stable release; we track the rolling tag and rely on the floating distro QEMU to keep pace with the userland. When sid drifts ahead of the emulator, packages we do not need (notably systemd) can fail to configure under QEMU — `ci_debian_container_bootstrap` tolerates that and only requires the build toolchain (see below), so such drift no longer fails the job. A last-known-good digest is recorded (commented) in that file as a fallback — uncomment it to re-pin only if drift ever breaks a package we actually need (e.g. an emulation SIGSEGV in gcc/binutils).

1. `ppc64-qemu-setup.sh` — register the `qemu-ppc64` binfmt handler on the Ubuntu host by installing the distro `qemu-user-static` (currently QEMU ~8.2; postinst registers with the `F` fix-binary flag); verify `flags:` includes `F`. We deliberately avoid `multiarch/qemu-user-static` (abandoned at 7.2.0) for a newer emulator.
2. `ppc64-be-build.sh` — cross-compile glibc CSU stubs on the host (`gcc-powerpc64-linux-gnu` + [`shared/csu-stubs.c`](shared/csu-stubs.c)); `docker run` the urbanogilson full image; bind-mount stub as `CSU_STUBS_PREBUILT`.
3. `ppc64-be-inner.sh` — Debian bootstrap (`ci_debian_container_bootstrap`, which tolerates non-essential package configure failures under QEMU and verifies the required toolchain via `ci_require_dpkg_installed`), `install-fpc-lazarus.sh` with `MAKE_BUILD_BACKEND=fpc`, `ci_preflight` (`ci_fpc_info_probe` for `-iV`/`-iTP`/`-iTO`, `ci_runtime_endian`), then `make.pas` (`RunFpcInfoProbeWithRetry`). Tune via `CI_FPC_PROBE_ATTEMPTS` / `CI_FPC_PROBE_DELAY_SECS` (shell) or `CI_FPC_PROBE_DELAY_MS` (make.pas).

`tonistiigi/binfmt` / `setup-qemu-action` are not used here — they do not support big-endian `ppc64`.

## OpenSSL 1.1 shim (FPC 3.2.2)

FPC 3.2.2 links against OpenSSL 1.1 sonames. On systems with OpenSSL 3 only:

- [`openssl-libssl11-shim-unix.sh`](openssl-libssl11-shim-unix.sh) — ELF `.so` symlinks (Linux, Debian containers, DragonFly).
- [`openssl-libssl11-shim-macos.sh`](openssl-libssl11-shim-macos.sh) — Homebrew `.dylib` symlinks on macOS.
- [`openssl-libssl11-shim-windows.sh`](openssl-libssl11-shim-windows.sh) — copies the runner's OpenSSL 3 DLLs (`libssl-3-x64.dll` / `libcrypto-3-x64.dll`, already on `PATH`) to the `-1_1-x64.dll` names FPC 3.2.2 expects. Optional bundled `libssl-1_1.dll` / `libcrypto-1_1.dll` next to [`make.pas`](../make.pas) cover local Win32 testing.

Called via `ci_openssl_hack` (native Windows/Unix/macOS) or `ci_debian_container_bootstrap` (arm32/ppc64 inner).

## Endian reporting

`ci_preflight` (in [`shared/common.sh`](shared/common.sh)) runs before `make.pas` on every `ci_build_standard` path. It logs one console line (`preflight: target=… endian=…`); `endian=unknown` also emits a `::warning::` annotation.

This is a **process-level** probe in the test environment (native runner, arm32 container, ppc64 guest, VMs). Do not use `lscpu` byte order under QEMU user-mode — it often reflects the host.

`ci_find_c_compiler` resolves `cc`/`gcc`/`g++` on `PATH` plus Solaris/OpenCSW paths (`/usr/gcc/*/bin/gcc`, etc.). Solaris prepare also adds `/usr/gcc/*/bin` to `PATH` for install scripts. Illumos `mktemp` requires a `XXXXXX` template — handled in `common.sh`.

`CIRunnerDetectDemo` also prints runtime and compile-time endian when the demo runs.

## Build backends

`MAKE_BUILD_BACKEND` in `make.yml` (default `fpc` when unset):

- `fpc` — `make.pas` compiles LPI/LPK with `fpc`; installer skips Lazarus.
- `lazbuild` — full Lazarus package registration + `lazbuild --build-all`.

`MAKE_PACKAGE_SCOPE` controls how many dependency packages `make.pas` compiles, in both backends (default `required` when unset; CI sets `all` explicitly in `make.yml`):

- `all` — compile every discovered package, so a package that fails to build on the target (e.g. a big-endian `{$MESSAGE FATAL}`) is caught even when no built project references it.
- `required` — compile only the dependency closure of the buildable projects. Faster, but a broken-but-unused package goes unnoticed.

## Logging & debugging

- `CI_DEBUG=1` enables `set -x` tracing in [`../install-fpc-lazarus.sh`](../install-fpc-lazarus.sh) (otherwise quiet, like the other scripts). Toggle it for a run via the `debug` checkbox on the workflow_dispatch "Run workflow" form — `make.yml` sets `CI_DEBUG` from it and forwards it into the QEMU/VM jobs. To trace locally, run the script with `CI_DEBUG=1`.
- `NO_COLOR` (any value) disables `make.pas` ANSI colors; colors are on by default since GitHub's log viewer renders them.
- `CI_FPC_PROBE_ATTEMPTS` / `CI_FPC_PROBE_DELAY_SECS` tune the shell `fpc -i*` retries; `CI_FPC_PROBE_DELAY_MS` tunes the `make.pas` equivalent.
