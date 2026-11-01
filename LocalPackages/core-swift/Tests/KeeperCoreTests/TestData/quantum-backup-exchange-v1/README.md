# Public Quantum backup exchange fixture

Never use these keys or addresses for funds. The password and every input secret are public test vectors.

`android-public-mixed-role-v1.tosqbk` was produced by Android's production recovery vault re-export at tosnetwork/android `a3001e7` (production code `c2412bf`), using `QuantumBackupExchangeDeviceTest#produceMixedRoleExchangeFile` on API24 ARM64. The test APK was run directly with instrumentation so its public cache artifact could be extracted before Gradle uninstalled it. The bytes were copied unchanged into this resource.

Password: `public exchange password 😀`. PRIMARY uses 23 `abandon` words followed by `chicken`, a phrase password with one ASCII space on each end of `public test password`, account 1/generation 19. RESCUE uses raw master bytes 0 through 31, account 2/generation 20. Both roles are included in one file, not independently held on separate devices.

Ciphertext: 4959 bytes, SHA256 `4a91af88ec7905f31dbfc1ecd60f9e71d87f57d35ab84ee3750108dbdb8d7b1b`.
Metadata: 822 bytes, SHA256 `8855206b6805d1c74d6177167e71df573d05a70de0dd26c4e3423b45c8eeca8e`.

The receiving test independently fixes the network profile and validates the original identity, both complete native public keys, exact provenance, derivation contexts, hash, and rejection controls. This does not establish online chain state, OS custody authentication, or an App restore/payment journey. Regeneration uses fresh salt/nonce; fixture replacement requires producer provenance and semantic/hash review, not weakened assertions.
