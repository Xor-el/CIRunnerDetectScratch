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
    # ELF e_ident[EI_DATA] at byte 5: 1=LE, 2=BE (no file(1) in minimal image)
    elf_data=$(od -An -j 5 -N 1 -t u1 /bin/bash | tr -d " ")
    echo "/bin/bash ELF data encoding: ${elf_data} (2=BE/MSB, 1=LE/LSB)"
    if [ "${elf_data}" != "2" ]; then
      echo "::error::BE ppc64 preflight: expected MSB ELF (2), got ${elf_data}" >&2
      exit 1
    fi
    echo "BE ppc64 preflight OK"
  '
