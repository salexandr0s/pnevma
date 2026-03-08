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
            sources: [
                "App/AppDelegate.swift",
                // Bridge
                "Bridge/PnevmaBridge.swift",
                // Core
                "Core/CommandBus.swift",
                "Core/ContentAreaView.swift",
                "Core/Log.swift",
                "Core/PaneLayoutEngine.swift",
                "Core/PnevmaJSON.swift",
                "Core/SessionBridge.swift",
                "Core/SessionPersistence.swift",
                "Core/SessionStore.swift",
                "Core/Workspace.swift",
                "Core/WorkspaceManager.swift",
                // Terminal
                "Terminal/TerminalConfig.swift",
                "Terminal/GhosttyConfigController.swift",
                "Terminal/GhosttySchema.swift",
                "Terminal/GhosttySettingsViewModel.swift",
                "Terminal/GhosttyThemeBrowserViewModel.swift",
                "Terminal/GhosttyThemeFile.swift",
                "Terminal/GhosttyThemeProvider.swift",
                "Terminal/TerminalHostView.swift",
                "Terminal/TerminalSurface.swift",
                // Panes
                "Panes/PaneProtocol.swift",
                "Panes/TaskBoardPane.swift",
                "Panes/AnalyticsPane.swift",
                "Panes/DailyBriefPane.swift",
                "Panes/NotificationsPane.swift",
                "Panes/ReviewPane.swift",
                "Panes/MergeQueuePane.swift",
                "Panes/DiffPane.swift",
                "Panes/SearchPane.swift",
                "Panes/FileBrowserPane.swift",
                "Panes/GhosttyThemeBrowserSheet.swift",
                "Panes/RulesManagerPane.swift",
                "Panes/SettingsPane.swift",
                "Panes/WorkflowPane.swift",
                "Panes/SshManagerPane.swift",
                "Panes/ReplayPane.swift",
                "Panes/BrowserPane.swift",
                "Panes/BrowserFind.swift",
                "Panes/BrowserMarkdown.swift",
                // Sidebar
                "Sidebar/SidebarView.swift",
                // Chrome
                "Chrome/CommandPalette.swift",
                "Chrome/SessionManagerView.swift",
                "Chrome/StatusBar.swift",
                "Chrome/TabBarView.swift",
                "Chrome/ProtectedActionSheet.swift",
                "Chrome/OnboardingFlow.swift",
                // Shared
                "Shared/DesignTokens.swift",
                "Shared/Extensions.swift",
                "Shared/ToastOverlay.swift",
            ],
            resources: [
                .copy("Resources/readability.min.js"),
                .copy("Resources/turndown.min.js"),
            ],
            swiftSettings: [
                .unsafeFlags([
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
