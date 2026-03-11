// =============================================================================
// Dead code extracted from the Pnevma Swift codebase.
// Moved here on 2026-03-11 as part of a dead code audit.
// Each section notes the original file and why it was dead.
// =============================================================================

// MARK: - From TerminalSurface.swift
// Methods with zero callers — Ghostty drives rendering through C-level callbacks.

/*
 func refresh() {
     guard let surface else { return }
     ghostty_surface_refresh(surface)
 }

 func draw() {
     guard let surface else { return }
     ghostty_surface_draw(surface)
 }

 func setOcclusion(_ occluded: Bool) {
     guard let surface else { return }
     ghostty_surface_set_occlusion(surface, occluded)
 }

 func hasSelection() -> Bool {
     guard let surface else { return false }
     return ghostty_surface_has_selection(surface)
 }

 func getSelection() -> String? {
     guard let surface else { return nil }
     var text = ghostty_text_s()
     guard ghostty_surface_read_selection(surface, &text) else { return nil }
     defer { ghostty_surface_free_text(surface, &text) }
     return Self.decodeSelectionText(text: text.text, length: Int(text.text_len))
 }

 // Stub equivalents (placeholder #else block):
 func refresh() {}
 func draw() {}
 func setOcclusion(_ occluded: Bool) {}
 func hasSelection() -> Bool { false }
 func getSelection() -> String? { nil }
*/

// MARK: - From GhosttyConfigController.swift
// Private methods with zero callers. Part of an earlier rollback mechanism
// that was never wired up.

/*
 // GhosttyManagedConfigCodec.ensureIncludeBlock — static, zero callers
 static func ensureIncludeBlock(in text: String, managedPath: URL) -> (text: String, alreadyIntegrated: Bool) {
     let block = includeBlock(for: managedPath)
     let newline = text.contains("\r\n") ? "\r\n" : "\n"
     if let startRange = text.range(of: markerStart), let endRange = text.range(of: markerEnd) {
         let replaceRange = startRange.lowerBound..<endRange.upperBound
         var updated = text
         updated.replaceSubrange(replaceRange, with: block)
         return (updated, true)
     }
     let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
     if trimmed.isEmpty {
         return (block + newline, false)
     }
     return (trimmed + newline + newline + block + newline, false)
 }

 // GhosttyConfigController private methods — zero callers
 private func restoreMainFile(_ content: String, to url: URL) throws {
     try writeAtomically(content, to: url)
 }

 private func restoreManagedFile(_ content: String, existed: Bool, to url: URL) throws {
     if existed {
         try writeAtomically(content, to: url)
         return
     }
     if FileManager.default.fileExists(atPath: url.path) {
         try FileManager.default.removeItem(at: url)
     }
 }

 private func changedKeys(previous: String, next: String) -> [String] {
     let previousParsed = GhosttyManagedConfigCodec.parseManagedFile(previous)
     let nextParsed = GhosttyManagedConfigCodec.parseManagedFile(next)
     let previousKeys = Set(previousParsed.values.keys).union(previousParsed.keybinds.isEmpty ? Set<String>() : Set(["keybind"]))
     let nextKeys = Set(nextParsed.values.keys).union(nextParsed.keybinds.isEmpty ? Set<String>() : Set(["keybind"]))
     let allKeys = previousKeys.union(nextKeys)
     return allKeys
         .filter { key in
             if key == "keybind" {
                 return previousParsed.keybinds.map(\.rawBinding) != nextParsed.keybinds.map(\.rawBinding)
             }
             return previousParsed.values[key] != nextParsed.values[key]
         }
         .sorted()
 }
*/

// MARK: - From PnevmaBridge.swift
// Public method never called — the bridge's init sets the callback directly.

/*
 func setSessionOutputCallback(_ cb: SessionOutputCallback, ctx: UnsafeMutableRawPointer?) {
     handleLock.lock()
     let h = handle
     handleLock.unlock()
     guard let h = h else { return }
     pnevma_set_session_output_callback(h, cb, ctx)
 }
*/

// MARK: - From ContentAreaView.swift
// Property with zero callers anywhere (not even tests).

/*
 var isZoomed: Bool { zoomedPaneID != nil }
*/
