// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TKCore",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "TKCore",
            targets: ["TKCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/onevcat/Kingfisher.git", .upToNextMajor(from: "7.0.0")),
        .package(path: "../TKUIKit"),
        .package(path: "../core-swift"),
        .package(path: "../Ledger"),
        .package(path: "../TKKeychain"),
        .package(path: "../TKLogging"),
        .package(path: "../TKFeatureFlags"),
    ],
    targets: [
        .target(
            name: "TKCore",
            dependencies: [
                .byName(name: "Kingfisher"),
                .product(name: "TKUIKitDynamic", package: "TKUIKit"),
                .product(name: "WalletCore", package: "core-swift"),
                .product(name: "TonTransport", package: "Ledger"),
                .product(name: "TKKeychain", package: "TKKeychain"),
                .product(name: "TKLogging", package: "TKLogging"),
                .product(name: "TKFeatureFlags", package: "TKFeatureFlags"),
            ],
            resources: [.process("Resources")],

            swiftSettings: [
                .treatAllWarnings(as: .error),
            ]
        ),
        .testTarget(
            name: "TKCoreTests",
            dependencies: ["TKCore"],

            swiftSettings: [
                .treatAllWarnings(as: .error),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
