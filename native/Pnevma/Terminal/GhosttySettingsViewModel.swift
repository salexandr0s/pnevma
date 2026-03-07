import AppKit
import SwiftUI

@MainActor
final class GhosttySettingsViewModel: ObservableObject {
    enum FilterMode: String, CaseIterable, Identifiable {
        case common
        case all
        case changed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .common:
                return "Common"
            case .all:
                return "All"
            case .changed:
                return "Changed"
            }
        }
    }

    @Published private(set) var snapshot: GhosttyConfigSnapshot?
    @Published var editedValues: [String: [String]] = [:]
    @Published var keybinds: [GhosttyManagedKeybind] = []
    @Published var searchText = ""
    @Published var filterMode: FilterMode = .common
    @Published var isLoading = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var validationMessages: [String] = []

    func load() {
        guard TerminalSurface.isRealRendererAvailable else {
            errorMessage = "Ghostty runtime is not available. Settings cannot be loaded."
            return
        }
        isLoading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try GhosttyConfigController.shared.loadSnapshot()
                self.apply(snapshot: snapshot)
                self.errorMessage = nil
                self.statusMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    func reload() {
        load()
    }

    func saveAndApply() {
        validationMessages = validateDraft()
        guard validationMessages.isEmpty else {
            errorMessage = validationMessages.joined(separator: "\n")
            return
        }

        do {
            let snapshot = try GhosttyConfigController.shared.saveAndApply(
                values: sanitizedEditedValues(),
                keybinds: sanitizedKeybinds()
            )
            apply(snapshot: snapshot)
            errorMessage = nil
            statusMessage = "Ghostty settings saved and applied."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revert() {
        guard let snapshot else { return }
        apply(snapshot: snapshot)
        statusMessage = "Reverted unsaved changes."
        errorMessage = nil
    }

    func validateOnly() {
        validationMessages = validateDraft()
        if validationMessages.isEmpty {
            statusMessage = "Draft validation passed."
            errorMessage = nil
        } else {
            errorMessage = validationMessages.joined(separator: "\n")
        }
    }

    var isDirty: Bool {
        guard let snapshot else { return false }
        return sanitizedEditedValues() != snapshot.managedValues || sanitizedKeybinds() != snapshot.keybinds
    }

    func descriptors(for category: GhosttyConfigCategory) -> [GhosttyConfigDescriptor] {
        GhosttySchema.descriptors
            .filter { $0.valueKind != .keybinds && $0.category == category }
            .filter(matchesFilter)
            .sorted { $0.title < $1.title }
    }

    func shouldShowCategory(_ category: GhosttyConfigCategory) -> Bool {
        !descriptors(for: category).isEmpty
    }

    func shouldShowKeybinds() -> Bool {
        switch filterMode {
        case .common, .all:
            return searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || "keybind".localizedCaseInsensitiveContains(searchText)
                || "keybinding".localizedCaseInsensitiveContains(searchText)
        case .changed:
            return sanitizedKeybinds() != snapshot?.keybinds
        }
    }

    func reset(key: String) {
        editedValues.removeValue(forKey: key)
    }

    func origin(for key: String) -> GhosttyValueOrigin {
        snapshot?.origin(for: key) ?? .inherited
    }

    func originLabel(for key: String) -> String {
        switch origin(for: key) {
        case .managed:
            return "Managed"
        case .manual:
            return "Manual"
        case .inherited:
            return "Default"
        }
    }

    func isChanged(_ key: String) -> Bool {
        sanitizedEditedValues()[key] != snapshot?.managedValues[key]
    }

    func rawTextBinding(for key: String, multiLine: Bool = false) -> Binding<String> {
        Binding(
            get: {
                if let managed = self.editedValues[key] {
                    return managed.joined(separator: multiLine ? "\n" : ", ")
                }
                return self.snapshot?.effectiveValues[key] ?? ""
            },
            set: { newValue in
                if multiLine {
                    let lines = newValue
                        .split(whereSeparator: \.isNewline)
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if lines.isEmpty {
                        self.editedValues.removeValue(forKey: key)
                    } else {
                        self.editedValues[key] = lines
                    }
                } else {
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        self.editedValues.removeValue(forKey: key)
                    } else {
                        self.editedValues[key] = [trimmed]
                    }
                }
            }
        )
    }

    func boolBinding(for key: String, fallback: Bool = false) -> Binding<Bool> {
        Binding(
            get: { self.currentBoolValue(for: key) ?? fallback },
            set: { self.editedValues[key] = [$0 ? "true" : "false"] }
        )
    }

    func stringChoiceBinding(for key: String, defaultValue: String) -> Binding<String> {
        Binding(
            get: { self.currentRawValue(for: key) ?? defaultValue },
            set: { self.editedValues[key] = [$0] }
        )
    }

    func intBinding(for key: String, defaultValue: Int = 0) -> Binding<Int> {
        Binding(
            get: { self.currentIntValue(for: key) ?? defaultValue },
            set: { self.editedValues[key] = [String($0)] }
        )
    }

    func doubleBinding(for key: String, defaultValue: Double = 0) -> Binding<Double> {
        Binding(
            get: { self.currentDoubleValue(for: key) ?? defaultValue },
            set: { self.editedValues[key] = [String($0)] }
        )
    }

    func colorBinding(for key: String, defaultHex: String) -> Binding<Color> {
        Binding(
            get: {
                let hex = self.currentRawValue(for: key) ?? defaultHex
                return Color(nsColor: NSColor(hexString: hex) ?? .controlAccentColor)
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                self.editedValues[key] = [nsColor.hexString ?? defaultHex]
            }
        )
    }

    func keybindActionDescriptor(for action: String) -> GhosttyKeybindActionDescriptor? {
        GhosttySchema.keybindActions.first { $0.name == action }
    }

    func addKeybind() {
        keybinds.append(GhosttyManagedKeybind())
    }

    func removeKeybind(_ keybindID: UUID) {
        keybinds.removeAll { $0.id == keybindID }
    }

    private func apply(snapshot: GhosttyConfigSnapshot) {
        self.snapshot = snapshot
        self.editedValues = snapshot.managedValues
        self.keybinds = snapshot.keybinds
        self.validationMessages = []
    }

    private func matchesFilter(_ descriptor: GhosttyConfigDescriptor) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty,
           !descriptor.key.localizedCaseInsensitiveContains(query),
           !descriptor.title.localizedCaseInsensitiveContains(query) {
            return false
        }

        switch filterMode {
        case .common:
            return descriptor.isCommon
        case .all:
            return true
        case .changed:
            return isChanged(descriptor.key)
        }
    }

    private func currentRawValue(for key: String) -> String? {
        editedValues[key]?.first ?? snapshot?.effectiveValues[key]
    }

    private func currentBoolValue(for key: String) -> Bool? {
        guard let raw = currentRawValue(for: key)?.lowercased() else { return nil }
        switch raw {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }

    private func currentIntValue(for key: String) -> Int? {
        guard let raw = currentRawValue(for: key) else { return nil }
        return Int(raw)
    }

    private func currentDoubleValue(for key: String) -> Double? {
        guard let raw = currentRawValue(for: key) else { return nil }
        return Double(raw)
    }

    private func sanitizedEditedValues() -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (key, values) in editedValues {
            let cleaned = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !cleaned.isEmpty {
                result[key] = cleaned
            }
        }
        return result
    }

    private func sanitizedKeybinds() -> [GhosttyManagedKeybind] {
        keybinds.filter { !$0.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func validateDraft() -> [String] {
        var messages: [String] = []
        var seenBindings = Set<String>()
        for binding in sanitizedKeybinds() {
            let trigger = binding.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            if trigger.isEmpty {
                messages.append("Each Ghostty keybinding must have a trigger.")
            }
            if let descriptor = keybindActionDescriptor(for: binding.action),
               descriptor.parameterPlaceholder != nil,
               binding.parameter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append("Ghostty keybinding action '\(binding.action)' requires a parameter.")
            }
            if !seenBindings.insert(binding.rawBinding).inserted {
                messages.append("Duplicate Ghostty keybinding: \(binding.rawBinding)")
            }
        }
        return messages
    }
}

private extension NSColor {
    convenience init?(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else {
            return nil
        }
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }

    var hexString: String? {
        guard let rgb = usingColorSpace(.deviceRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}
