import os

enum Log {
    static let general = Logger(subsystem: "com.pnevma.app", category: "general")
    static let bridge = Logger(subsystem: "com.pnevma.app", category: "bridge")
    static let terminal = Logger(subsystem: "com.pnevma.app", category: "terminal")
    static let persistence = Logger(subsystem: "com.pnevma.app", category: "persistence")
    static let workspace = Logger(subsystem: "com.pnevma.app", category: "workspace")
}
