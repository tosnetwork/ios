#!/bin/sh
set -e

# POSIX-portable: resolve paths relative to the repo root instead of using the
# bash-only ${BASH_SOURCE} (which breaks under dash / non-bash /bin/sh).
cd "$(git rev-parse --show-toplevel)"
GIT_DIR="$(git rev-parse --git-common-dir)"

mkdir -p "${GIT_DIR}/hooks"
cp -f scripts/hooks/commit-msg "${GIT_DIR}/hooks/commit-msg"
chmod +x "${GIT_DIR}/hooks/commit-msg"
