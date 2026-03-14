import Foundation

enum WorkspacePathDisplayFormatter {
    static func shortenedLocalPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let standardized = NSString(string: expanded).standardizingPath
        let home = NSString(string: NSHomeDirectory()).standardizingPath

        let displayPath: String
        if standardized == home {
            displayPath = "~"
        } else if standardized.hasPrefix(home + "/") {
            displayPath = "~" + String(standardized.dropFirst(home.count))
        } else {
            displayPath = standardized
        }

        let isHomeRelative = displayPath.hasPrefix("~/")
        let components = displayPath.split(separator: "/").map(String.init)
        guard components.count > 4 else {
            return displayPath
        }

        let pieces = Array(components.prefix(2)) + ["…"] + Array(components.suffix(2))
        let shortened = pieces.joined(separator: "/")
        return isHomeRelative ? shortened : "/" + shortened
    }
}
