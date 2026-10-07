// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WalletCore",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(name: "WalletCore", targets: ["KeeperCore"]),
    ],
    // Compatibility boundary: these upstream product names are protocol and
    // supply-chain identities, not TOS product branding. See
    // docs/legacy-ton-compatibility-boundary.md before changing them.
    dependencies: [
        .package(path: "../TKLocalize"),
        .package(path: "../TKKeychain"),
        .package(path: "../Ledger"),
        .package(path: "../TKLogging"),
        .package(path: "../tron-swift"),
        .package(path: "../TKFeatureFlags"),
        .package(url: "https://github.com/ton-connect/kit-ios.git", exact: "0.3.2"),
        .package(url: "https://github.com/tonkeeper/CryptoSwift", revision: "1d31a1ffb6043655f3faba9d160db67b2e547e49"),
        .package(url: "https://github.com/tonkeeper/PunycodeSwift", revision: "30a462bdb4398ea835a3585472229e0d74b36ba5"),
        .package(url: "https://github.com/tonkeeper/ton-swift", exact: "1.0.32"),
        .package(url: "https://github.com/tonkeeper/URKit", .upToNextMinor(from: "16.0.0")),
        .package(url: "https://github.com/tonkeeper/ton-api-swift", exact: "0.6.0"),
        .package(url: "https://github.com/tonkeeper/battery-api-swift", .upToNextMinor(from: "3.0.0")),
        .package(url: "https://github.com/apple/swift-openapi-runtime", .upToNextMinor(from: "0.3.0")),
    ],
    targets: [
        .binaryTarget(name: "TOSFeeState", path: "Generated/TOSFeeState.xcframework"),
        .target(name: "TOSPQNative", path: "Sources/TOSPQNative",
            exclude: ["CMakeLists.txt", "PROVENANCE.json", "V5R2-PROVENANCE.json", "V5R2-LMS-PROVENANCE.json", "vendor/MLDSA-LICENSE", "vendor/lms-reference/license.txt", "vendor/lms-reference/SOURCE.json", "vendor/slhdsa/LICENSE", "vendor/slhdsa/PROVENANCE.md", "vendor/slhdsa/SHA256SUMS"],
            sources: ["vendor/lms/wallet-lms-sign-c.cpp", "vendor/lms-reference/hss_derive.c", "vendor/lms-reference/hss_zeroize.c", "vendor/lms-reference/lm_common.c", "vendor/lms-reference/lm_ots_common.c", "vendor/lms-reference/lm_ots_sign.c", "vendor/lms-reference/endian.c", "vendor/lms-reference/hash.c", "vendor/lms/lms-fee.cpp", "vendor/lms/wallet-lms-fee-c.cpp", "tos_v5r2.c", "tos_v5r2_kdf.c", "vendor/slhdsa/slh_dsa.c", "vendor/slhdsa/slh_sha2.c",
                "vendor/slhdsa/sha2_256.c", "vendor/slhdsa/sha2_512.c", "tos_pq.c", "falcon512-native.c", "vendor/mldsa/mldsa_native.c",
                "vendor/falcon/falcon.c", "vendor/falcon/codec.c", "vendor/falcon/common.c",
                "vendor/falcon/shake.c", "vendor/falcon/vrfy.c", "vendor/falcon/keygen.c",
                "vendor/falcon/sign.c", "vendor/falcon/fft.c", "vendor/falcon/fpr.c", "vendor/falcon/rng.c"],
            publicHeadersPath: "include", cSettings: [
                .define("EXT_SHA256_H", to: "\"tos_lms_sha256.h\""), .headerSearchPath("vendor/lms-reference"), .headerSearchPath("."), .headerSearchPath("vendor/mldsa"), .headerSearchPath("vendor/falcon"), .headerSearchPath("vendor/slhdsa"),
                .define("MLD_CONFIG_FILE", to: "\"mldsa-config.h\""),
                .define("FALCON_FPEMU", to: "1"), .define("FALCON_FPNATIVE", to: "0"),
                .define("FALCON_AVX2", to: "0"), .define("FALCON_FMA", to: "0"),
                .define("FALCON_PREFIX", to: "tos_mobile_falcon_inner"),
                .define("FALCON_RAND_GETENTROPY", to: "0"), .define("FALCON_RAND_URANDOM", to: "0"),
                .define("FALCON_RAND_WIN32", to: "0")],
            cxxSettings: [.headerSearchPath("."), .headerSearchPath("vendor/lms-reference"), .headerSearchPath("vendor/slhdsa"), .define("TOS_LMS_PORTABLE_SHA256", to: "1")]),
        .target(
            name: "CoreComponents",
            dependencies: ["TOSPQNative", "TOSFeeState",
                .product(name: "TonSwift", package: "ton-swift"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
                .product(name: "TKKeychain", package: "TKKeychain"),
            ],

            resources: [.copy("Resources/TOSPQNotices.txt")],
            swiftSettings: [
                .treatAllWarnings(as: .error),
            ]
        ),
        .testTarget(
            name: "CoreComponentsTests",
            dependencies: [
                "CoreComponents",
                .product(name: "TKKeychain", package: "TKKeychain"),
            ],

            resources: [.copy("TestData/tos-pq-backup-vectors.json")],
            swiftSettings: [
                .treatAllWarnings(as: .error),
            ]
        ),
        .target(
            name: "KeeperCore",
            dependencies: [
                .product(name: "URKit", package: "URKit"),
                .product(name: "TKLocalize", package: "TKLocalize"),
                .product(name: "TKKeychain", package: "TKKeychain"),
                .product(name: "TonTransport", package: "Ledger"),
                .product(name: "TonSwift", package: "ton-swift"),
                .product(name: "TonAPI", package: "ton-api-swift"),
                .product(name: "TKBatteryAPI", package: "battery-api-swift"),
                .product(name: "TonStreamingAPI", package: "ton-api-swift"),
                .product(name: "TronSwift", package: "tron-swift"),
                .product(name: "TronSwiftAPI", package: "tron-swift"),
                .product(name: "TKFeatureFlags", package: "TKFeatureFlags"),
                .product(name: "Punycode", package: "PunycodeSwift"),
                .target(name: "TonConnectAPI"),
                .target(name: "SwapAPI"),
                .target(name: "CoreComponents"),
                .product(name: "TKLogging", package: "TKLogging"),
                .product(name: "TONWalletKit", package: "kit-ios"),
            ],
            path: "Sources/KeeperCore",
            resources: [
                .copy("PackageResources/DefaultRemoteConfiguration.json"),
                .copy("PackageResources/known_accounts.json"),
            ]
        ),
        .testTarget(
            name: "KeeperCoreTests",
            dependencies: [
                "KeeperCore",
            ],
            resources: [.copy("TestData/tos-v5r2-initial-recovery.json"), .copy("TestData/tip-1-dns-v1.json"), .copy("TestData/tos-pq-auth-vectors.json"), .copy("TestData/tos-pq-receipt-vectors.json"), .copy("TestData/tos-v5-reference-vectors.json"), .copy("TestData/tos-mnemonic-goldens.json"), .copy("TestData/tos-legacy-wallet-rpc-snapshots.json")],

            swiftSettings: [
                .treatAllWarnings(as: .error),
            ]
        ),
        .target(
            name: "TonConnectAPI",
            dependencies: [
                .product(
                    name: "OpenAPIRuntime",
                    package: "swift-openapi-runtime"
                ),
            ],
            path: "Packages/TonConnectAPI",
            sources: ["Sources"],

            swiftSettings: [
                .treatAllWarnings(as: .error),
            ]
        ),
        .target(
            name: "SwapAPI",
            dependencies: [
                .product(
                    name: "OpenAPIRuntime",
                    package: "swift-openapi-runtime"
                ),
            ],
            path: "Packages/SwapAPI",
            sources: ["Sources"],
            swiftSettings: [
                .treatAllWarnings(as: .error),
            ]
        ),
        .testTarget(
            name: "WalletCoreTests",
            dependencies: [
                "KeeperCore",
            ],

            swiftSettings: [
                .treatAllWarnings(as: .error),
            ]
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
