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
let ghosttyXCFrameworkPath = "../vendor/ghostty/macos/GhosttyKit.xcframework"

struct GhosttyLibraryLayout {
    let directory: String
    let binaryName: String
}

func libraryLayout(at directory: String) -> GhosttyLibraryLayout? {
    for binaryName in ["libghostty.a", "libghostty-fat.a"] {
        if fileManager.fileExists(atPath: "\(directory)/\(binaryName)") {
            return GhosttyLibraryLayout(directory: directory, binaryName: binaryName)
        }
    }

    return nil
}

func resolveGhosttyLibrary() -> GhosttyLibraryLayout? {
    let preferredPaths = [
        "\(ghosttyXCFrameworkPath)/macos-arm64_x86_64",
        "\(ghosttyXCFrameworkPath)/macos-arm64",
        "\(ghosttyXCFrameworkPath)/macos-x86_64",
    ]

    for path in preferredPaths {
        if let layout = libraryLayout(at: path) {
            return layout
        }
    }

    guard let entries = try? fileManager.contentsOfDirectory(atPath: ghosttyXCFrameworkPath) else {
        return nil
    }

    for entry in entries.sorted() where entry.hasPrefix("macos-") {
        let candidate = "\(ghosttyXCFrameworkPath)/\(entry)"
        if let layout = libraryLayout(at: candidate) {
            return layout
        }
    }

    return nil
}

let ghosttyLibrary = resolveGhosttyLibrary()

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

if let ghosttyLibrary {
    pnevmaLinkerSettings.append(
        contentsOf: [
            .unsafeFlags([
                "-L", ghosttyLibrary.directory,
                "\(ghosttyLibrary.directory)/\(ghosttyLibrary.binaryName)",
            ]),
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
