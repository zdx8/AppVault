// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppVault",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VaultCore", targets: ["VaultCore"]),
        .executable(name: "AppVault", targets: ["AppVaultApp"]),
        .executable(name: "VaultSelfTest", targets: ["VaultSelfTest"])
    ],
    targets: [
        .target(
            name: "VaultCore",
            dependencies: [],
            path: "Sources/VaultCore"
        ),
        .executableTarget(
            name: "AppVaultApp",
            dependencies: ["VaultCore"],
            path: "Sources/AppVaultApp"
        ),
        .executableTarget(
            name: "VaultSelfTest",
            dependencies: ["VaultCore"],
            path: "Sources/VaultSelfTest"
        )
    ]
)
