import AppKit
#if canImport(GhosttyKit)
import GhosttyKit
#endif

enum AppCursorRole {
    case text
    case verticalText
    case defaultControl
    case linkPointer
    case horizontalResize
    case verticalResize
    case dragIdle
    case dragActive
    case contextualMenu
    case crosshair
    case operationNotAllowed
}

enum AppCursor {
    static func cursor(for role: AppCursorRole) -> NSCursor {
        switch role {
        case .text:
            return .iBeam
        case .verticalText:
            return .iBeamCursorForVerticalLayout
        case .defaultControl:
            return .arrow
        case .linkPointer:
            return .pointingHand
        case .horizontalResize:
            return .resizeLeftRight
        case .verticalResize:
            return .resizeUpDown
        case .dragIdle:
            return .openHand
        case .dragActive:
            return .closedHand
        case .contextualMenu:
            return .contextualMenu
        case .crosshair:
            return .crosshair
        case .operationNotAllowed:
            return .operationNotAllowed
        }
    }

    #if canImport(GhosttyKit)
    static func cursor(forGhosttyShape shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            return cursor(for: .text)
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            return cursor(for: .verticalText)
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            return cursor(for: .linkPointer)
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            return cursor(for: .crosshair)
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            return cursor(for: .dragIdle)
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            return cursor(for: .dragActive)
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            return cursor(for: .operationNotAllowed)
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE:
            return cursor(for: .verticalResize)
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE:
            return cursor(for: .horizontalResize)
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
            return cursor(for: .contextualMenu)
        default:
            return cursor(for: .defaultControl)
        }
    }
    #endif
}
