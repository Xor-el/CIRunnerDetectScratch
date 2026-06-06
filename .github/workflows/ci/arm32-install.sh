#!/usr/bin/env bash
set -euo pipefail

CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates git build-essential openssl
OPENSSL_USE_SUDO=0 bash "$CI_ROOT/openssl-linux.sh" /usr/lib/arm-linux-gnueabihf
