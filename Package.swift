// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RSwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "rswitcher", targets: ["RSwitcher"]),
        .executable(name: "rswitcher-tests", targets: ["TestRunner"])
    ],
    targets: [
        .target(name: "SwitcherCore"),
        .executableTarget(
            name: "RSwitcher",
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
