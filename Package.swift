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
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.18/libGLESv2.xcframework.zip",
            checksum: "62319373b2183d47d198db68ce931c475c55092b7a937228e51f3244bda634f5"
        ),
        .binaryTarget(
            name: "libEGL",
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.18/libEGL.xcframework.zip",
            checksum: "f78d509307b7bbb102b93746d787de09cef881a8e614c2ae1e1b94de7ff7772e"
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
