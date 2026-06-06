#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates git build-essential gcc binutils openssl

CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSSL_USE_SUDO=0 bash "$CI_ROOT/openssl-linux.sh"

# shellcheck source=lib/common.sh
source "$CI_ROOT/lib/common.sh"
ci_init_paths
ci_build_standard
