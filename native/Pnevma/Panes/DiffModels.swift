import Foundation

// MARK: - Data Models

struct DiffFile: Identifiable, Decodable {
    var id: String { path }
    let path: String
    let hunks: [DiffHunk]

    /// Inferred status based on hunk content — used for the file-tree icon/color.
    var inferredStatus: String {
        let allLines = hunks.flatMap { $0.lines }
        let hasAdditions = allLines.contains { $0.type == .addition }
        let hasDeletions = allLines.contains { $0.type == .deletion }
        switch (hasAdditions, hasDeletions) {
        case (true, false): return "added"
        case (false, true): return "deleted"
        default: return "modified"
        }
    }
}

struct DiffHunk: Identifiable, Decodable {
    let id = UUID()
    let header: String
    /// Raw line strings from the backend, decoded into DiffLine objects.
    let lines: [DiffLine]

    private enum CodingKeys: String, CodingKey { case header, lines }

    init(header: String, lines: [DiffLine]) {
        self.header = header
        self.lines = lines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decode(String.self, forKey: .header)
        let rawLines = try container.decode([String].self, forKey: .lines)
        lines = rawLines.map(DiffLine.init(rawString:))
    }
}

struct DiffLine: Identifiable {
    let id = UUID()
    let type: DiffLineType
    /// The line content without the leading prefix character.
    let content: String

    /// Parse a raw line string (e.g. "+foo", "-bar", " baz") into a DiffLine.
    init(rawString: String) {
        switch rawString.first {
        case "+":
            type = .addition
            content = String(rawString.dropFirst())
        case "-":
            type = .deletion
            content = String(rawString.dropFirst())
        default:
            type = .context
            // Drop the leading space when present; keep content as-is otherwise.
            content = rawString.hasPrefix(" ") ? String(rawString.dropFirst()) : rawString
        }
    }
}

enum DiffLineType: String {
    case context, addition, deletion
}

// MARK: - Diff Colors

import SwiftUI

enum DiffColors {
    static let additionContent = Color(.sRGB, red: 0.6, green: 1.0, blue: 0.6)
    static let deletionContent = Color(.sRGB, red: 1.0, green: 0.6, blue: 0.6)
    static let additionBackground = Color.green.opacity(0.18)
    static let deletionBackground = Color.red.opacity(0.18)
}

/// A task item carrying just the fields needed for the diff task selector.
struct DiffTaskItem: Identifiable {
    let id: String
    let title: String
    let status: String
}

// MARK: - Backend param/response types (internal for ViewModel use)

/// Top-level response from the `review.diff` backend command.
struct TaskDiffResponse: Decodable {
    let taskID: String
    let diffPath: String
    let files: [DiffFile]

    var taskId: String { taskID }
}

struct BackendDiffTask: Decodable {
    let id: String
    let title: String
    let status: String
    let priority: String
}
