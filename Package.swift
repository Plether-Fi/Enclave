// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EnclaveCLI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.4.1"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.3"),
    ],
    targets: [
        .executableTarget(
            name: "EnclaveCLI",
            dependencies: ["BigInt", "CryptoSwift"],
            path: "EnclaveCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("DefaultIsolation=MainActor"),
            ]
        ),
        .testTarget(
            name: "EnclaveTests",
            dependencies: ["EnclaveCLI"],
            path: "Tests/EnclaveTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("DefaultIsolation=MainActor"),
            ]
        ),
    ]
)
