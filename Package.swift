// swift-tools-version: 6.0

import PackageDescription
import Foundation

// XCTest поставляется только с полным Xcode. На машине с одними Command Line
// Tools модуль XCTest недоступен, и `swift test` падает на этапе компиляции.
// Поэтому XCTest-цель подключается только когда явно запрошено через
// переменную окружения RSW_ENABLE_XCTEST=1 (например, при сборке под Xcode).
// Основной набор тестов — самодостаточный `TestRunner` (`swift run TestRunner`).
let enableXCTest = ProcessInfo.processInfo.environment["RSW_ENABLE_XCTEST"] == "1"

var targets: [Target] = [
    .target(name: "SwitcherCore"),
    .executableTarget(
        name: "RSW",
        dependencies: ["SwitcherCore"]
    ),
    .executableTarget(
        name: "TestRunner",
        dependencies: ["SwitcherCore"],
        path: "Tests/TestRunner"
    )
]

if enableXCTest {
    targets.append(
        .testTarget(
            name: "SwitcherCoreTests",
            dependencies: ["SwitcherCore"]
        )
    )
}

let package = Package(
    name: "RSW",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "rsw", targets: ["RSW"])
    ],
    targets: targets,
    swiftLanguageModes: [.v5]
)
