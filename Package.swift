// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ShakeFeedbackKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ShakeFeedbackKit", targets: ["ShakeFeedbackKit"]),
    ],
    dependencies: [
        // Match GigaBitcoin/secp256k1.swift to whatever downstream apps
        // pin — they share the same upstream C library, but mixing the
        // two forks in one build produces duplicate secp256k1 symbols.
        // (Pre-cutover this package used 21-DOT-DEV/swift-secp256k1 to
        // coexist with NDKSwift; that constraint went away when the
        // downstream Podcastr app stopped depending on NDKSwift.)
        .package(url: "https://github.com/GigaBitcoin/secp256k1.swift", from: "0.23.1"),
    ],
    targets: [
        .binaryTarget(
            name: "ShakeFeedbackCoreFFI",
            path: "Frameworks/ShakeFeedbackCore.xcframework"
        ),
        .target(
            name: "ShakeFeedbackKit",
            dependencies: [
                "ShakeFeedbackCoreFFI",
                .product(name: "P256K", package: "secp256k1.swift"),
            ]
        ),
    ]
)
