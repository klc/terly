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
        // Fork of upstream 1.14.0 carrying the Metal BufferPool memory-growth
        // fix (unbounded IOAccelerator regions under htop-like workloads).
        // Drop back to upstream once the fix lands there.
        .package(
            url: "https://github.com/klc/SwiftTerm.git",
            revision: "99f1bc935fd9937cf7361fd56d3cf89b082e0112"
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
