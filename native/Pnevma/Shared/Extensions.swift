import Cocoa
import SwiftUI

// MARK: - JSONValue (arbitrary backend JSON)

/// Lightweight recursive JSON value type for fields whose schema is not fully known at
/// compile time. Used by ReviewPane (pack blob), DailyBriefPane (event payload),
/// and browser tool result payloads.
enum JSONValue: Codable, Equatable {
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let values):
            try container.encode(values)
        }
    }

    init(any value: Any?) {
        guard let value else {
            self = .null
            return
        }

        switch value {
        case let value as JSONValue:
            self = value
        case let value as NSNull:
            _ = value
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(value)
        case let value as Int8:
            self = .int(Int(value))
        case let value as Int16:
            self = .int(Int(value))
        case let value as Int32:
            self = .int(Int(value))
        case let value as Int64:
            self = .int(Int(value))
        case let value as UInt:
            self = .int(Int(value))
        case let value as UInt8:
            self = .int(Int(value))
        case let value as UInt16:
            self = .int(Int(value))
        case let value as UInt32:
            self = .int(Int(value))
        case let value as UInt64:
            if value <= UInt64(Int.max) {
                self = .int(Int(value))
            } else {
                self = .double(Double(value))
            }
        case let value as Double:
            self = .double(value)
        case let value as Float:
            self = .double(Double(value))
        case let value as String:
            self = .string(value)
        case let value as URL:
            self = .string(value.absoluteString)
        case let value as [Any]:
            self = .array(value.map(JSONValue.init(any:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init(any:)))
        case let value as [String: JSONValue]:
            self = .object(value)
        default:
            self = .string(String(describing: value))
        }
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
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
