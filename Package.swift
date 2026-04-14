// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "AsyncGL",
    platforms: [
        .iOS(.v14),
        .macCatalyst(.v14),
        .tvOS(.v14),
        .macOS(.v11),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "AsyncGL",
            targets: ["AsyncGL"]
        ),
        .library(
            name: "AsyncGLANGLE",
            targets: ["AsyncGLANGLE"]
        ),
        .library(name: "ANGLE", targets: [
            "libGLESv2",
            "libEGL",
        ]),
    ],
    targets: [
        .binaryTarget(
            name: "libGLESv2",
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.21/libGLESv2.xcframework.zip",
            checksum: "5e15a0e6978f31a68d3405d97d0e0b6b17813f1f430ffe858a3eada7ad3f4881"
        ),
        .binaryTarget(
            name: "libEGL",
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.21/libEGL.xcframework.zip",
            checksum: "33a1b3b980b1ee5a2635d14bc526140ff2ab4fee49ae56d4493a15848af1cf8e"
        ),
        .target(
            name: "AsyncGL",
            path: "AsyncGL",
            publicHeadersPath: "include",
            cSettings: [
                .define("GL_SILENCE_DEPRECATION"),
            ]
        ),
        .target(
            name: "AsyncGLANGLE",
            dependencies: [
                .target(name: "libGLESv2"),
                .target(name: "libEGL"),
            ],
            path: "AsyncGLANGLE",
            publicHeadersPath: "include",
            cSettings: [
                .define("GL_SILENCE_DEPRECATION"),
                .define("GL_GLEXT_PROTOTYPES"),
                .define("EGL_EGLEXT_PROTOTYPES"),
            ]
        )
    ]
)
