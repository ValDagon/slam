// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "slam",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "slam", targets: ["SwiftAgent"]),
    ],
    dependencies: [
        // The only third-party dependency allowed by the spec (§2).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")
    ],
    targets: [
        .target(
            name: "KeychainACL",
            path: "Sources/KeychainACL",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "SwiftAgent",
            dependencies: [
                "KeychainACL",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/SwiftAgent"
        ),
        // Тесты используют import Testing: нужен полный Xcode-тулчейн
        // (в голых CLT нет ни XCTest, ни встроенного Testing).
        .testTarget(
            name: "SwiftAgentTests",
            dependencies: [
                "SwiftAgent",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
