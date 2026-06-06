#!/usr/bin/env bash
set -euo pipefail

docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
if ! ls /proc/sys/fs/binfmt_misc/qemu-ppc64* >/dev/null 2>&1; then
  echo "::error::qemu-ppc64 binfmt handler not registered"
  ls /proc/sys/fs/binfmt_misc/
  exit 1
fi
docker run --rm --platform linux/ppc64 \
  urbanogilson/debian-debootstrap-ports:ppc64-forky-sid \
  bash -c '
    set -euo pipefail
    m=$(uname -m)
    echo "uname -m: ${m}"
    if [ "${m}" != "ppc64" ]; then
      echo "::error::BE ppc64 preflight: expected uname ppc64, got ${m}" >&2
      exit 1
    fi
    elf=$(file -b /bin/bash)
    echo "/bin/bash: ${elf}"
    if echo "${elf}" | grep -qi "LSB"; then
      echo "::error::BE ppc64 preflight: userspace is little-endian ELF" >&2
      exit 1
    fi
    if ! echo "${elf}" | grep -qi "MSB"; then
      echo "::error::BE ppc64 preflight: /bin/bash is not big-endian MSB ELF" >&2
      exit 1
    fi
    echo "BE ppc64 preflight OK"
  '
