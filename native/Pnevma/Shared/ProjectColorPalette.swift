import SwiftUI

/// Deterministic project color assignment.
/// Same project name always produces the same color, across sessions and machines.
/// User-set `customColor` on a workspace always overrides the automatic color.
enum ProjectColorPalette {
    /// 12 perceptually distinct hues.
    /// Avoids pure red (reserved for errors) and pure green (reserved for success).
    private static let hues: [(h: Double, s: Double, b: Double)] = [
        (0.58, 0.55, 0.85),  // steel blue
        (0.78, 0.45, 0.80),  // lavender
        (0.45, 0.50, 0.75),  // teal
        (0.12, 0.60, 0.90),  // amber
        (0.92, 0.45, 0.82),  // rose
        (0.35, 0.50, 0.72),  // sage
        (0.68, 0.50, 0.78),  // indigo
        (0.05, 0.55, 0.88),  // coral
        (0.52, 0.45, 0.78),  // cyan
        (0.82, 0.40, 0.75),  // mauve
        (0.25, 0.55, 0.70),  // olive
        (0.15, 0.50, 0.85),  // peach
    ]

    /// Stable color for a project name using FNV-1a hash.
    static func color(for projectName: String) -> Color {
        let hash = projectName.utf8.reduce(into: UInt64(0xcbf29ce484222325)) { h, byte in
            h ^= UInt64(byte)
            h &*= 0x100000001b3
        }
        let entry = hues[Int(hash % UInt64(hues.count))]
        return Color(hue: entry.h, saturation: entry.s, brightness: entry.b)
    }

    /// NSColor variant for AppKit usage.
    static func nsColor(for projectName: String) -> NSColor {
        let hash = projectName.utf8.reduce(into: UInt64(0xcbf29ce484222325)) { h, byte in
            h ^= UInt64(byte)
            h &*= 0x100000001b3
        }
        let entry = hues[Int(hash % UInt64(hues.count))]
        return NSColor(
            calibratedHue: entry.h,
            saturation: entry.s,
            brightness: entry.b,
            alpha: 1.0
        )
    }

    /// Opacity modulation based on workspace operational state.
    /// Returns the opacity to apply to the project color.
    static func stateOpacity(_ state: WorkspaceOperationalState) -> Double {
        switch state {
        case .attention: return 1.0
        case .active: return 0.90
        case .review: return 0.60
        case .idle: return 0.25
        }
    }
}
