// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RSW",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "rsw", targets: ["RSW"])
    ],
    targets: [
        .target(name: "SwitcherCore"),
        .executableTarget(
            name: "RSW",
            dependencies: ["SwitcherCore"]
        ),
        .executableTarget(
            name: "TestRunner",
            dependencies: ["SwitcherCore"],
            path: "Tests/TestRunner"
        ),
        .testTarget(
            name: "SwitcherCoreTests",
            dependencies: ["SwitcherCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
