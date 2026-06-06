#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/csw/bin:/usr/local/bin:$PATH"
pkgutil -y -i bash curl git gmake
