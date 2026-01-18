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
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.16/libGLESv2.xcframework.zip",
            checksum: "b1919363bd65d4170009e78aca8b0830a1edeec730b8a51acac0bcfa19151348"
        ),
        .binaryTarget(
            name: "libEGL",
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.16/libEGL.xcframework.zip",
            checksum: "2533cc8dfa1636a9f1e75f46600cc2aa22ba3efd876b0c77eccfa55a4e4945be"
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
