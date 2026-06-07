// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VectorScroll",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VectorScroll", targets: ["VectorScroll"])
    ],
    targets: [
        .executableTarget(
            name: "VectorScroll",
            swiftSettings: [
                .unsafeFlags(["-warnings-as-errors"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
