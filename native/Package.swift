// swift-tools-version: 5.9
// SPM build path — alternative to xcodebuild.
// Note: SPM cannot directly consume a .xcodeproj, so this file
// describes the same target for `swift build` / CI use.
//
// Prerequisites before building:
//   just rust-build          # produces target/aarch64-apple-darwin/debug/libpnevma_bridge.a
//   just ghostty-build       # produces vendor/ghostty/zig-out/lib/libghostty.xcframework
//                            #   and vendor/ghostty/include/ghostty.h

import PackageDescription

let package = Package(
    name: "Pnevma",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Pnevma",
            path: "Pnevma",
            exclude: [
                "Pnevma.entitlements",
            ],
            sources: [
                // App
                "App/PnevmaApp.swift",
                "App/AppDelegate.swift",
                // Bridge
                "Bridge/PnevmaBridge.swift",
                // Core
                "Core/CommandBus.swift",
                "Core/ContentAreaView.swift",
                "Core/PaneLayoutEngine.swift",
                "Core/SessionBridge.swift",
                "Core/SessionPersistence.swift",
                "Core/Workspace.swift",
                "Core/WorkspaceManager.swift",
                // Terminal
                "Terminal/TerminalConfig.swift",
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
                "Panes/RulesManagerPane.swift",
                "Panes/SettingsPane.swift",
                "Panes/WorkflowPane.swift",
                "Panes/SshManagerPane.swift",
                "Panes/ReplayPane.swift",
                // Sidebar
                "Sidebar/SidebarView.swift",
                // Chrome
                "Chrome/CommandPalette.swift",
                "Chrome/StatusBar.swift",
                "Chrome/ProtectedActionSheet.swift",
                "Chrome/OnboardingFlow.swift",
                // Shared
                "Shared/DesignTokens.swift",
                "Shared/Extensions.swift",
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-import-objc-header", "Pnevma/Bridge/Pnevma-Bridging-Header.h",
                ]),
            ],
            linkerSettings: [
                // Rust staticlib — built by `just rust-build`
                .unsafeFlags([
                    "-L", "../target/aarch64-apple-darwin/debug",
                ]),
                .linkedLibrary("pnevma_bridge"),

                // Ghostty static library — built by `just ghostty-build`
                // The XCFramework is at vendor/ghostty/zig-out/lib/libghostty.xcframework
                // For SPM builds we link the inner .a directly.
                .unsafeFlags([
                    "-L", "../vendor/ghostty/zig-out/lib",
                    // XCFramework inner path for Apple Silicon macOS slice:
                    "-F", "../vendor/ghostty/zig-out/lib/libghostty.xcframework/macos-arm64",
                ]),
                .linkedLibrary("ghostty"),

                // System frameworks
                .linkedFramework("Cocoa"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                // Metal — required by ghostty's GPU renderer
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),

                // System libraries
                .linkedLibrary("resolv"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "PnevmaTests",
            dependencies: [],
            path: "../PnevmaTests"
        ),
    ]
)
