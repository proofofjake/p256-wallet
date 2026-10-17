// swift-tools-version: 6.0
import PackageDescription

// Networking and orchestration around the signing core. Everything that decides what gets signed lives in
// P256WalletCore (the `core` submodule); build it first with ./core/scripts/build-swift.sh.
let package = Package(
    name: "WalletClient",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WalletClient", targets: ["WalletClient"]),
    ],
    dependencies: [
        .package(path: "../core/bindings/swift"),
    ],
    targets: [
        .target(name: "WalletClient", dependencies: [.product(name: "P256WalletCore", package: "swift")]),
        .testTarget(name: "WalletClientTests", dependencies: ["WalletClient"]),
    ]
)
