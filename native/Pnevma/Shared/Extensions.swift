import Cocoa
import SwiftUI

// MARK: - JSONValue (arbitrary backend JSON)

/// Lightweight recursive JSON value type for fields whose schema is not fully known at
/// compile time. Used by ReviewPane (pack blob) and DailyBriefPane (event payload).
enum JSONValue: Decodable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            self = .null
        }
    }

    /// Returns the array of string values under the given key if this is an object
    /// and the key maps to an array of strings or objects with a "description"/"text" key.
    func acceptanceCriteriaStrings() -> [String] {
        guard case .object(let dict) = self,
              case .array(let items) = dict["acceptance_criteria"] else {
            return []
        }
        return items.compactMap { item in
            switch item {
            case .string(let s):
                return s
            case .object(let obj):
                if case .string(let s) = obj["description"] { return s }
                if case .string(let s) = obj["text"] { return s }
                return nil
            default:
                return nil
            }
        }
    }
}

// MARK: - NSView Extensions

/// Extensions on NSView and SwiftUI types used throughout the app.
extension NSView {
    /// Embed a SwiftUI view inside this NSView using NSHostingView.
    /// Automatically injects the shared theme provider into the SwiftUI environment.
    @discardableResult
    func addSwiftUISubview<Content: View>(_ view: Content) -> NSHostingView<some View> {
        let themed = view.environment(GhosttyThemeProvider.shared)
        let host = NSHostingView(rootView: themed)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        return host
    }
}
