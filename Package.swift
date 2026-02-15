// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Enclave",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.4.1"),
    ],
    targets: [
        .executableTarget(
            name: "Enclave",
            dependencies: [
                .product(name: "BigInt", package: "BigInt"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
