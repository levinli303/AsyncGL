// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "AsyncGL",
    platforms: [
        .iOS(.v12),
        .macOS(.v10_13),
        .macCatalyst(.v13),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "AsyncGL",
            targets: ["AsyncGL"]
        ),
        .library(name: "ANGLE", targets: [
            "libGLESv2",
            "libEGL",
        ])
    ],
    targets: [
        .binaryTarget(name: "libGLESv2", path: "XCFrameworks/libGLESv2.xcframework"),
        .binaryTarget(name: "libEGL", path: "XCFrameworks/libEGL.xcframework"),
        .target(
            name: "AsyncGL",
            path: "AsyncGL",
            publicHeadersPath: "include",
            cSettings: [
                .define("GL_SILENCE_DEPRECATION"),
            ]
        )
    ]
)
