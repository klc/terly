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
        // Fork tracking upstream main, carrying only the line-accurate scroll
        // wheel + scrollSensitivity work that is under review upstream as
        // migueldeicaza/SwiftTerm#600. The Metal BufferPool memory-growth fix
        // this fork used to carry has landed upstream (#598), so it is no
        // longer part of the delta. Drop back to upstream once #600 lands.
        .package(
            url: "https://github.com/klc/SwiftTerm.git",
            revision: "983cfbfaaac43cc9635d8c6983d4c4167b9b7bfd"
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
