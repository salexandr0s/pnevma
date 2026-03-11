// swift-tools-version: 5.9
// SPM build path — alternative to xcodebuild.
// Note: SPM cannot directly consume a .xcodeproj, so this file
// describes the same target for `swift build` / CI use.
//
// Prerequisites before building:
//   just rust-build          # produces target/aarch64-apple-darwin/debug/libpnevma_bridge.a
//   just ghostty-build       # produces vendor/ghostty/macos/GhosttyKit.xcframework
//                            #   and vendor/ghostty/include/ghostty.h

import PackageDescription
import Foundation

let fileManager = FileManager.default
let ghosttyLibraryPath = "../vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64"

var pnevmaLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L", "../target/aarch64-apple-darwin/debug",
    ]),
    .linkedLibrary("pnevma_bridge"),
    .linkedLibrary("c++"),

    .linkedFramework("AppIntents"),
    .linkedFramework("Carbon"),
    .linkedFramework("Cocoa"),
    .linkedFramework("Security"),
    .linkedFramework("SwiftUI"),
    .linkedFramework("SystemConfiguration"),
    .linkedFramework("Metal"),
    .linkedFramework("MetalKit"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("WebKit"),

    .linkedLibrary("resolv"),
    .linkedLibrary("sqlite3"),
]

if fileManager.fileExists(atPath: ghosttyLibraryPath) {
    pnevmaLinkerSettings.append(
        contentsOf: [
            .unsafeFlags([
                "-L", ghosttyLibraryPath,
            ]),
            .linkedLibrary("ghostty"),
        ]
    )
}

let package = Package(
    name: "Pnevma",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Pnevma", targets: ["Pnevma"]),
    ],
    targets: [
        .target(
            name: "Pnevma",
            path: "Pnevma",
            exclude: [
                "Pnevma.entitlements",
                "App/PnevmaApp.swift",
                "Assets.xcassets",
                "Resources/AppIcon.icon",
            ],
            resources: [
                .copy("Resources/readability.min.js"),
                .copy("Resources/turndown.min.js"),
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-enable-bare-slash-regex",
                    "-disable-bridging-pch",
                    "-import-objc-header", "Pnevma/Bridge/Pnevma-Bridging-Header.h",
                ]),
            ],
            linkerSettings: pnevmaLinkerSettings
        ),
        .testTarget(
            name: "PnevmaTests",
            dependencies: ["Pnevma"],
            path: "PnevmaTests"
        ),
    ]
)
