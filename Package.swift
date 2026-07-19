// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSHConfigurator",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "SSHConfigCore", targets: ["SSHConfigCore"]),
        .executable(name: "SSHConfigurator", targets: ["SSHConfigurator"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            from: "1.15.0"
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            from: "2.0.0"
        ),
    ],
    targets: [
        .target(name: "SSHConfigCore"),
        .executableTarget(
            name: "SSHConfigurator",
            dependencies: [
                "SSHConfigCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Askpass/terly-askpass.sh"),
            ]
        ),
        .testTarget(
            name: "SSHConfigCoreTests",
            dependencies: ["SSHConfigCore"]
        ),
        .testTarget(
            name: "SSHConfiguratorTests",
            dependencies: ["SSHConfigurator"]
        ),
    ]
)
