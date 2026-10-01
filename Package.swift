// swift-tools-version:6.0

import PackageDescription

// The plugin authoring SDK for LingXiAgent.
//
// A plugin author links this and nothing else: no Core, no session store, no
// permission engine, no provider runtime. The package is Foundation-only and
// talks to a host over JSON Lines IPC, which is what lets an out-of-process
// binary written by someone outside this repository work at all.
let package = Package(
    name: "LingXiPluginSDK",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "LingXiPluginSDK",
            targets: ["LingXiPluginSDK"]
        )
    ],
    targets: [
        .target(
            name: "LingXiPluginSDK"
        ),
        .testTarget(
            name: "LingXiPluginSDKTests",
            dependencies: ["LingXiPluginSDK"]
        )
    ]
)
