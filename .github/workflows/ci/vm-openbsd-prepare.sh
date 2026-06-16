#!/bin/sh
set -eu

# OpenBSD VM prepare. Runs under the VM's /bin/sh; bash is installed here (the
# 'run' step is `bash ...`). pkg_add reads the mirror from /etc/installurl
# (baked into the image), so no PKG_PATH is needed.
#
#   bash  - the 'run' step shell
#   curl  - ci_download's fetcher (OpenBSD base ships neither curl nor `fetch`)
#   gmake - ci_default_make_cmd maps *BSD -> gmake
#   git   - clone Lazarus when MAKE_BUILD_BACKEND=lazbuild
#   rsync - vmactions copies the workspace back out via rsync at job end
pkg_add bash curl git gmake rsync
