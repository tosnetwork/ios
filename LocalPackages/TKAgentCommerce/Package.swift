// swift-tools-version: 6.2

import PackageDescription

// TKAgentCommerce is the owner-controlled Native buyer client: it decodes the
// canonical Quote, escrow, and settlement facts and projects the buyer-facing
// "is it paid?" decision from finalized escrow state. It holds no keys, opens no
// network connections, and asserts no Gateway authority. Its only side effect is
// the private atomic purchase journal used to prevent funding twice after a crash.
let package = Package(
    name: "TKAgentCommerce",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "TKAgentCommerce",
            targets: ["TKAgentCommerce"]
        ),
    ],
    targets: [
        .target(
            name: "TKAgentCommerce",
            swiftSettings: [
                .treatAllWarnings(as: .error),
            ]
        ),
        .testTarget(
            name: "TKAgentCommerceTests",
            dependencies: ["TKAgentCommerce"],
            resources: [.process("Resources")],
            swiftSettings: [
                .treatAllWarnings(as: .error),
            ]
        ),
    ]
)
