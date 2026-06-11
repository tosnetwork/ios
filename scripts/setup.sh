#!/bin/sh
set -e

cd "$(git rev-parse --show-toplevel)"

# Install git hooks.
sh ./scripts/hooks/setup_hooks.sh

# Provision local Firebase config without depending on any external key store.
#
# TOS does not use Firebase, but the SDKs are not yet removed, so the Xcode
# "Firebase plist" build phase still expects a GoogleService-Info.plist per
# flavor. We copy a committed placeholder (dummy values) into each flavor
# folder. To use a real Firebase project, replace these with your own plist —
# the Firebase resource directory is git-ignored.
TEMPLATE="./scripts/firebase/GoogleService-Info.template.plist"
FIREBASE_ROOT="./Tonkeeper/Resources/Firebase"

for flavor in Tonkeeper TonkeeperDev TonkeeperXDebug TonkeeperXRelease TonkeeperUK; do
  dest_dir="${FIREBASE_ROOT}/${flavor}"
  dest="${dest_dir}/GoogleService-Info.plist"
  if [ -f "${dest}" ]; then
    echo "Keeping existing ${dest}"
  else
    mkdir -p "${dest_dir}"
    cp "${TEMPLATE}" "${dest}"
    echo "Created placeholder ${dest}"
  fi
done
