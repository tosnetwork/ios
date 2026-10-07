# Embedded V5R2 proof development build

`make compile` and project-scheme tests generate `TOSProofVerify.xcframework`
from the immutable TOS revision in `scripts/v5r2-proof-revision.txt`. The builder
checks the source checkout, refreshes public contract generation, builds device
arm64 and simulator arm64/x86_64 slices, checks platform markers, and packages the
C verification and durable-checkpoint interfaces. Identical output bytes retain
the existing generated framework; generated libraries are not committed.

A clean matching source checkout can be supplied with `TOS_PROOF_ROOT`, its
configured host build with `TOS_PROOF_HOST_BUILD`, and a slice-build directory
with `TOS_PROOF_BUILD_ROOT`. Without overrides the builder uses a source checkout
and build cache under `.native/v5r2-proof`. CMake, Ninja, Xcode command-line tools,
and native dependency build tools are required.

The Swift bridge currently validates raw proof results only. Current wallet
account/configuration binding, authenticated transport, trusted-anchor
provisioning, and the iOS private no-backup checkpoint session remain separate
unfinished steps. Framework construction and simulator tests do not establish
physical-device custody or transaction authorization acceptance.
