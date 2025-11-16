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
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.9/libGLESv2.xcframework.zip",
            checksum: "2d9bd5f2000ac4f4c413940f1962325d0eb33d2c14aca5fc8910f1ea30efa959"
        ),
        .binaryTarget(
            name: "libEGL",
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.9/libEGL.xcframework.zip",
            checksum: "2d9bd5f2000ac4f4c413940f1962325d0eb33d2c14aca5fc8910f1ea30efa959"
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
