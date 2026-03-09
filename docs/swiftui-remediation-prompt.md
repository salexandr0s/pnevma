# SwiftUI Remediation Prompt

Use the prompt below to apply the latest high-confidence Swift/SwiftUI review findings to the native app.

```text
You are working in `/Users/nationalbank/pnevma`.

Apply the following high-confidence Swift and SwiftUI fixes in the native macOS app. Keep changes surgical, follow `AGENTS.md`, use modern Swift 6.2+ and SwiftUI APIs, and do not introduce third-party frameworks. Only fix the issues listed here unless you discover a directly related compile break.

Files and required changes:

1. `native/Pnevma/Chrome/OnboardingFlow.swift`
   - Around `native/Pnevma/Chrome/OnboardingFlow.swift:159`, make `openProject()` actually open the selected workspace instead of only setting `projectOpened = true`.
   - Reuse the app’s existing workspace-opening behavior if possible rather than duplicating logic.
   - Around `native/Pnevma/Chrome/OnboardingFlow.swift:196`, do not treat scaffold failures as success. Surface an error state in the onboarding UI and keep `projectOpened` false on failure.

2. `native/Pnevma/Panes/Workflow/WorkflowAgentsView.swift`
   - Around `native/Pnevma/Panes/Workflow/WorkflowAgentsView.swift:82`, `:88`, `:94`, and `:98`, replace icon-only buttons with text-backed labels such as `Button("Edit Agent", systemImage: "pencil")`, then use `.labelStyle(.iconOnly)` if the visual should stay icon-only.
   - Around `native/Pnevma/Panes/Workflow/WorkflowAgentsView.swift:199` and `:206`, extract the inline `Binding(get:set:)` used for `systemPrompt` out of `body` into a dedicated binding property or helper.

3. Replace `onTapGesture` primary actions with `Button` controls for proper accessibility semantics:
   - `native/Pnevma/Panes/FileBrowserPane.swift` around `native/Pnevma/Panes/FileBrowserPane.swift:169`
   - `native/Pnevma/Panes/NotificationsPane.swift` around `native/Pnevma/Panes/NotificationsPane.swift:54`
   - `native/Pnevma/Panes/GhosttyThemeBrowserSheet.swift` around `native/Pnevma/Panes/GhosttyThemeBrowserSheet.swift:70`

4. `native/Pnevma/Panes/SettingsPane.swift`
   - Around `native/Pnevma/Panes/SettingsPane.swift:121` and `native/Pnevma/Panes/SettingsPane.swift:563`, replace old `specifier:` formatting with modern `FormatStyle` APIs.

5. `native/Pnevma/Terminal/TerminalConfig.swift`
   - Around `native/Pnevma/Terminal/TerminalConfig.swift:104`, replace `String(format:)` hex-color formatting with Swift-native formatting.

6. Replace user-entered filtering/search matching with `localizedStandardContains()` where appropriate:
   - `native/Pnevma/Terminal/GhosttySettingsViewModel.swift` around `native/Pnevma/Terminal/GhosttySettingsViewModel.swift:129`, `:130`, `:253`, and `:254`
   - `native/Pnevma/Panes/Browser/BrowserModels.swift` around `native/Pnevma/Panes/Browser/BrowserModels.swift:133`
   - `native/Pnevma/Terminal/GhosttyThemeBrowserViewModel.swift` around `native/Pnevma/Terminal/GhosttyThemeBrowserViewModel.swift:35`

Implementation notes:
- Preserve current UI layout and behavior unless a listed fix requires a small structural change.
- Favor `Button(action:)` or `Button("Title", systemImage:, action:)` over tap gestures for tappable UI.
- Keep VoiceOver and keyboard accessibility intact or improved.
- Do not add unrelated refactors.

Validation:
- Run the most targeted native tests you can for the touched files.
- If practical, run a native build or relevant native test target after the code changes.
- Report any failures you did not fix because they were unrelated.

Deliverables:
- Short summary of files changed
- Validation commands run and results
- Any follow-up issues intentionally left untouched
```
