#!/bin/sh
set -e

cd "$(git rev-parse --show-toplevel)"

# Install git hooks. TOS uses no Firebase or analytics SDKs, so there is no key
# store or remote config to fetch — setup is fully self-contained.
sh ./scripts/hooks/setup_hooks.sh
