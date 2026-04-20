// swift-tools-version:6.1

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
        .library(name: "ANGLE", targets: [
            "libGLESv2",
            "libEGL",
        ]),
    ],
    traits: [
        .trait(name: "OpenGL", description: "Use native OpenGL (default)"),
        .trait(name: "ANGLE", description: "Use ANGLE for OpenGL ES via EGL"),
        .default(enabledTraits: ["OpenGL"]),
    ],
    targets: [
        .binaryTarget(
            name: "libGLESv2",
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.23/libGLESv2.xcframework.zip",
            checksum: "57e880544e281a6ce2835f620fca8a85932e3aad0d33f6c1db304b45ac4ea690"
        ),
        .binaryTarget(
            name: "libEGL",
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.23/libEGL.xcframework.zip",
            checksum: "238f50059474cd33307a8ea9249a4007b4ef3831405397f70e7764f92d04297c"
        ),
        .target(
            name: "AsyncGL",
            dependencies: [
                .target(name: "libGLESv2", condition: .when(traits: ["ANGLE"])),
                .target(name: "libEGL", condition: .when(traits: ["ANGLE"])),
            ],
            path: "AsyncGL",
            publicHeadersPath: "include",
            cSettings: [
                .define("GL_SILENCE_DEPRECATION"),
                .define("GL_GLEXT_PROTOTYPES", .when(traits: ["ANGLE"])),
                .define("EGL_EGLEXT_PROTOTYPES", .when(traits: ["ANGLE"])),
            ]
        ),
    ]
)
