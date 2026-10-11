# Quantum fee state source build

`fee-state-bundle` is exported from the shared TOS Rust implementation using
`scripts/export-quantum-fee-state.py` in that repository. Its manifest records source
hashes and the standalone lockfile retains the canonical dependency versions.
Do not fork the journal/schedule/cache logic in this repository.

Install the Rust toolchain declared in the bundle and its targets:

```
cd Native/fee-state-bundle
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
```

From the repository root, `make prepare_quantum_fee_state` builds an ignored
XCFramework from source for device and both simulator architectures. `make
compile` and `make test_project_scheme` run this prerequisite automatically.
Run it before opening the project directly in Xcode on a fresh checkout.
The static framework uses a separate module directory to avoid collisions with
other static library headers.

The Swift session serializes its operations. Close it explicitly and handle a
failed close before discarding it. Its counters/time/enrollment inputs must come
from authenticated chain state. Capacity and cached signature verification do
not approve signing or broadcast; current route, expiry and consumption checks
remain the wallet service's responsibility.
