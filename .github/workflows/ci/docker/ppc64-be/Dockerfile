# syntax=docker/dockerfile:1
# Thin layer: embed qemu-ppc64-static for reliable BE ppc64 user-mode emulation.
# See https://blog.michael.kuron-germany.de/2023/06/emulating-ppc64-inside-docker/

ARG QEMU_IMAGE=multiarch/qemu-user-static:x86_64-ppc64-7.2.0-1
ARG BASE_IMAGE=urbanogilson/debian-debootstrap-ports:ppc64-forky-sid

FROM --platform=$BUILDPLATFORM ${QEMU_IMAGE} AS qemu

FROM ${BASE_IMAGE}
COPY --from=qemu /usr/bin/qemu-ppc64-static /usr/bin/qemu-ppc64-static
COPY --from=qemu /usr/bin/qemu-ppc64-static /usr/bin/qemu-ppc64
RUN test -x /usr/bin/qemu-ppc64-static && test -x /usr/bin/qemu-ppc64
