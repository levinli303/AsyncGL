// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "AsyncGL",
    products: [
        .library(
            name: "AsyncGL",
            targets: ["AsyncGL"]),
    ],
    targets: [
        .target(
            name: "AsyncGL",
            path: "AsyncGL",
            cSettings: [
                .define("GL_SILENCE_DEPRECATION"),
                .headerSearchPath("../GL")
            ]
        )
    ]
)
