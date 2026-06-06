#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
ci_init_paths

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates git build-essential openssl
OPENSSL_USE_SUDO=0 bash "$CI_ROOT/openssl-linux.sh" /usr/lib/arm-linux-gnueabihf
