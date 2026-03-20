import Foundation
import os

struct SessionBindingEnvVar: Decodable, Equatable {
    let key: String
    let value: String
}

struct SessionRecoveryOption: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let description: String
    let enabled: Bool
}

struct SessionBindingDescriptor: Decodable, Equatable {
    let sessionID: String
    let backend: String?
    let durability: String?
    let lifecycleState: String?
    let mode: String
    let cwd: String
    let launchCommand: String?
    let env: [SessionBindingEnvVar]
    let waitAfterCommand: Bool
    let recoveryOptions: [SessionRecoveryOption]

    var isLiveAttach: Bool { mode == "live_attach" }
    var isDetachedRecovery: Bool {
        matchesLifecycle("detached") || matchesLifecycle("reattaching")
    }

    private func matchesLifecycle(_ value: String) -> Bool {
        lifecycleState?.caseInsensitiveCompare(value) == .orderedSame
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacing("'", with: "'\\''"))'"
    }

    func makeLaunchConfiguration() -> TerminalSurfaceLaunchConfiguration? {
        guard let command = launchCommand.flatMap({ cmd in
            let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }) else {
            return nil  // No live terminal — archived mode
        }
        return TerminalSurfaceLaunchConfiguration(
            workingDirectory: cwd,
            command: "/bin/sh -lc \(shellQuote(command))",
            env: env.map { TerminalSurfaceEnvironmentVariable(key: $0.key, value: $0.value) },
            waitAfterCommand: waitAfterCommand,
            initialInput: nil
        )
    }
}

struct SessionRecoveryResult: Decodable, Equatable {
    let ok: Bool
    let action: String
    let newSessionID: String?
}

struct SessionScrollbackSlice: Decodable, Equatable {
    let sessionID: String
    let startOffset: UInt64
    let endOffset: UInt64
    let totalBytes: UInt64
    let data: String
}

private struct SessionCreateParams: Encodable {
    let name: String
    let cwd: String
    let command: String
    let remoteTarget: SessionCreateRemoteTargetParams?
}

private struct SessionCreateRemoteTargetParams: Encodable, Equatable {
    let sshProfileID: String
    let sshProfileName: String
    let host: String
    let port: Int
    let user: String
    let identityFile: String?
    let proxyJump: String?
    let remotePath: String

    init(_ target: WorkspaceRemoteTarget) {
        sshProfileID = target.sshProfileID
        sshProfileName = target.sshProfileName
        host = target.host
        port = target.port
        user = target.user
        identityFile = target.identityFile
        proxyJump = target.proxyJump
        remotePath = target.remotePath
    }
}

private struct SessionCreateResponse: Decodable {
    let sessionID: String
    let binding: SessionBindingDescriptor
}

private struct SessionBindingParams: Encodable {
    let sessionID: String
}

private struct SessionResizeParams: Encodable {
    let sessionID: String
    let cols: Int
    let rows: Int
}

private struct SessionRecoveryParams: Encodable {
    let sessionID: String
    let action: String
}

private struct SessionScrollbackParams: Encodable {
    let sessionID: String
    let limit: Int
}

enum SessionBridgeError: LocalizedError {
    case missingProjectPath
    case staleSession(String)

    var errorDescription: String? {
        switch self {
        case .missingProjectPath:
            return "No active project is available for terminal session creation."
        case .staleSession(let sessionID):
            return "Session \(sessionID) is no longer available. Start a new session."
        }
    }
}

/// Native coordinator for backend-managed terminal sessions.
protocol SessionBridging: Sendable {
    func createSession(
        name: String,
        workingDirectory requestedWorkingDirectory: String?,
        command requestedCommand: String?,
        remoteTarget: WorkspaceRemoteTarget?
    ) async throws -> SessionBindingDescriptor
    func binding(for sessionID: String) async throws -> SessionBindingDescriptor
    func scrollback(for sessionID: String, limit: Int) async throws -> SessionScrollbackSlice
    func recover(sessionID: String, action: String) async throws -> SessionRecoveryResult
    func sendResize(sessionID: String, columns: UInt16, rows: UInt16) async
}

extension SessionBridging {
    func scrollback(for sessionID: String) async throws -> SessionScrollbackSlice {
        try await scrollback(for: sessionID, limit: 128 * 1024)
    }
}

@MainActor
final class SessionBridge: SessionBridging {
    static var shared: (any SessionBridging)?

    private let commandBus: any CommandCalling
    private let activeWorkspacePath: () -> String?
    var defaultShell: String?

    init(
        commandBus: any CommandCalling,
        activeWorkspacePath: @escaping () -> String?
    ) {
        self.commandBus = commandBus
        self.activeWorkspacePath = activeWorkspacePath
    }

    func createSession(
        name: String = "Terminal",
        workingDirectory requestedWorkingDirectory: String?,
        command requestedCommand: String? = nil,
        remoteTarget: WorkspaceRemoteTarget? = nil
    ) async throws -> SessionBindingDescriptor {
        let cwd = requestedWorkingDirectory ?? activeWorkspacePath()
        guard let cwd else {
            throw SessionBridgeError.missingProjectPath
        }

        let response: SessionCreateResponse = try await commandBus.call(
            method: "session.new",
            params: SessionCreateParams(
                name: name,
                cwd: cwd,
                command: requestedCommand ?? (remoteTarget == nil ? defaultShell ?? "" : ""),
                remoteTarget: remoteTarget.map(SessionCreateRemoteTargetParams.init)
            )
        )
        return response.binding
    }

    func binding(for sessionID: String) async throws -> SessionBindingDescriptor {
        try await commandBus.call(
            method: "session.binding",
            params: SessionBindingParams(sessionID: sessionID)
        )
    }

    func scrollback(for sessionID: String, limit: Int = 128 * 1024) async throws -> SessionScrollbackSlice {
        try await commandBus.call(
            method: "session.scrollback",
            params: SessionScrollbackParams(sessionID: sessionID, limit: limit)
        )
    }

    func recover(sessionID: String, action: String) async throws -> SessionRecoveryResult {
        try await commandBus.call(
            method: "session.recovery.execute",
            params: SessionRecoveryParams(sessionID: sessionID, action: action)
        )
    }

    func sendResize(sessionID: String, columns: UInt16, rows: UInt16) async {
        do {
            let _: OkResponse = try await commandBus.call(
                method: "session.resize",
                params: SessionResizeParams(
                    sessionID: sessionID,
                    cols: Int(columns),
                    rows: Int(rows)
                )
            )
        } catch {
            Log.workspace.debug(
                "Ignoring terminal resize update for session \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

}

actor ActiveSessionBridge: SessionBridging {
    private var current: (any SessionBridging)?

    func setCurrent(_ current: (any SessionBridging)?) {
        self.current = current
    }

    func createSession(
        name: String,
        workingDirectory requestedWorkingDirectory: String?,
        command requestedCommand: String?,
        remoteTarget: WorkspaceRemoteTarget?
    ) async throws -> SessionBindingDescriptor {
        guard let current else {
            throw SessionBridgeError.missingProjectPath
        }
        return try await current.createSession(
            name: name,
            workingDirectory: requestedWorkingDirectory,
            command: requestedCommand,
            remoteTarget: remoteTarget
        )
    }

    func binding(for sessionID: String) async throws -> SessionBindingDescriptor {
        guard let current else {
            throw SessionBridgeError.missingProjectPath
        }
        return try await current.binding(for: sessionID)
    }

    func scrollback(for sessionID: String, limit: Int = 128 * 1024) async throws -> SessionScrollbackSlice {
        guard let current else {
            throw SessionBridgeError.missingProjectPath
        }
        return try await current.scrollback(for: sessionID, limit: limit)
    }

    func recover(sessionID: String, action: String) async throws -> SessionRecoveryResult {
        guard let current else {
            throw SessionBridgeError.missingProjectPath
        }
        return try await current.recover(sessionID: sessionID, action: action)
    }

    func sendResize(sessionID: String, columns: UInt16, rows: UInt16) async {
        await current?.sendResize(sessionID: sessionID, columns: columns, rows: rows)
    }

}
