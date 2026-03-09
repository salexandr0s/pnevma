Pnevma SwiftUI-Pro Comprehensive Review & Improvement Plan

Status: We got cut off at phase 3. Phases were not done in order. Please investigate and continue.                                                                                                │
│                                                                                                                                                           │
│ Context                                                                                                                                                   │
│                                                                                                                                                           │
│ Pnevma is a native macOS terminal-first execution workspace (Swift/AppKit + embedded Ghostty). The existing docs/uiux_plan.md covers design token gaps,   │
│ interaction polish, HIG compliance, and basic accessibility. This plan extends that audit using the full swiftui-pro skill ruleset — covering deprecated  │
│ APIs, modern data flow, view composition, performance, accessibility depth, Swift modernization, and code hygiene. Together, these two plans form the     │
│ complete improvement roadmap.                                                                                                                             │
│                                                                                                                                                           │
│ This plan is organized into phases that can be executed independently. Each phase targets a specific swiftui-pro concern area. The existing uiux_plan.md  │
│ items (Groups A–F) remain valid and are not duplicated here — this plan covers net-new findings only.                                                     │
│                                                                                                                                                           │
│ ---                                                                                                                                                       │
│ Phase 0: Infrastructure (Enables All Other Phases)                                                                                                        │
│                                                                                                                                                           │
│ 0A. Extend DesignTokens with Typography & CornerRadius                                                                                                    │
│                                                                                                                                                           │
│ Already specified in uiux_plan.md A1 — execute that first.                                                                                                │
│                                                                                                                                                           │
│ 0B. Add Reduced Motion helpers (AppKit + SwiftUI)                                                                                                         │
│                                                                                                                                                           │
│ Already specified in uiux_plan.md A2 — execute that first.                                                                                                │
│                                                                                                                                                           │
│ 0C. Inject theme into SwiftUI environment via addSwiftUISubview()                                                                                         │
│                                                                                                                                                           │
│ File: native/Pnevma/Shared/Extensions.swift:65-76                                                                                                         │
│                                                                                                                                                           │
│ The addSwiftUISubview() helper creates NSHostingView but never injects environment objects. Every SwiftUI view that needs theme colors must reference     │
│ GhosttyThemeProvider.shared directly — breaking testability and idiomatic SwiftUI data flow.                                                              │
│                                                                                                                                                           │
│ Fix: Modify the helper to inject the theme provider:                                                                                                      │
│ func addSwiftUISubview<Content: View>(_ view: Content) -> NSHostingView<some View> {                                                                      │
│     let themed = view.environmentObject(GhosttyThemeProvider.shared)                                                                                      │
│     let host = NSHostingView(rootView: themed)                                                                                                            │
│     // ... constraints unchanged                                                                                                                          │
│ }                                                                                                                                                         │
│                                                                                                                                                           │
│ Then gradually migrate child views from @ObservedObject private var theme = GhosttyThemeProvider.shared to @EnvironmentObject var theme:                  │
│ GhosttyThemeProvider. This is a prerequisite for the Phase 2 data flow migration.                                                                         │
│                                                                                                                                                           │
│ Also update: AppDelegate.swift (sidebar, settings, onboarding), ToastOverlay.swift (toast hosting view), OnboardingFlow.swift (onboarding window).        │
│                                                                                                                                                           │
│ ---                                                                                                                                                       │
│ Phase 1: Deprecated & Non-Modern API Fixes                                                                                                                │
│                                                                                                                                                           │
│ 1A. foregroundColor() → foregroundStyle()                                                                                                                 │
│                                                                                                                                                           │
│ 8 occurrences in 1 file:                                                                                                                                  │
│ - native/Pnevma/Panes/WorkflowPane.swift — lines 868, 1675, 1678, 1681, 1721, 1725, 1752, 1783                                                            │
│                                                                                                                                                           │
│ 1B. cornerRadius() → clipShape(.rect(cornerRadius:))                                                                                                      │
│                                                                                                                                                           │
│ 4 occurrences in 1 file:                                                                                                                                  │
│ - native/Pnevma/Panes/WorkflowPane.swift — lines 482, 1716, 1757, 1784                                                                                    │
│                                                                                                                                                           │
│ 1C. showsIndicators: false → .scrollIndicators(.hidden)                                                                                                   │
│                                                                                                                                                           │
│ 8 occurrences in 4 files:                                                                                                                                 │
│ - Panes/TaskBoardPane.swift — lines 294, 467, 564, 796, 850                                                                                               │
│ - Panes/WorkflowPane.swift — lines 399, 911                                                                                                               │
│ - Sidebar/SidebarView.swift — line 74                                                                                                                     │
│                                                                                                                                                           │
│ 1D. Task.sleep(nanoseconds:) → Task.sleep(for:)                                                                                                           │
│                                                                                                                                                           │
│ 4 occurrences in 4 files:                                                                                                                                 │
│ - Panes/BrowserPane.swift:148 → .milliseconds(200)                                                                                                        │
│ - Panes/BrowserFind.swift:242 → .milliseconds(100)                                                                                                        │
│ - Panes/SettingsPane.swift:1052 → .milliseconds(300)                                                                                                      │
│ - Shared/ToastOverlay.swift:38 → .seconds(2.5)                                                                                                            │
│                                                                                                                                                           │
│ 1E. String(format:) → FormatStyle                                                                                                                         │
│                                                                                                                                                           │
│ 6 occurrences in 5 files:                                                                                                                                 │
│ - Panes/TaskBoardPane.swift:690 — String(format: "$%.2f", cost) → Text(cost, format: .currency(code: "USD"))                                              │
│ - Panes/DailyBriefPane.swift:330 — same pattern                                                                                                           │
│ - Panes/AnalyticsPane.swift:121 — "$%.4f" → .currency(code: "USD").precision(.fractionLength(4))                                                          │
│ - Panes/ReviewPane.swift:206 — same as TaskBoard                                                                                                          │
│ - Panes/ReplayPane.swift:390 — time formatting "%d:%02d" → use Duration.formatted()                                                                       │
│ - Terminal/TerminalConfig.swift:104 — hex color "#%02X%02X%02X" — keep as-is (no FormatStyle for hex colors)                                              │
│                                                                                                                                                           │
│ 1F. replacingOccurrences(of:with:) → replacing(_:with:)                                                                                                   │
│                                                                                                                                                           │
│ 21 occurrences across 6 files:                                                                                                                            │
│ - Panes/DailyBriefPane.swift:90                                                                                                                           │
│ - Panes/BrowserMarkdown.swift:119-125 (7 calls)                                                                                                           │
│ - Panes/BrowserFind.swift:10-15 (5 calls)                                                                                                                 │
│ - Panes/WorkflowPane.swift:1229-1233 (5 calls)                                                                                                            │
│ - Terminal/GhosttyConfigController.swift:196-264 (4 calls)                                                                                                │
│ - Terminal/GhosttySettingsViewModel.swift:334                                                                                                             │
│                                                                                                                                                           │
│ 1G. Date() → Date.now                                                                                                                                     │
│                                                                                                                                                           │
│ 11 occurrences across 5 files:                                                                                                                            │
│ - Panes/TaskBoardPane.swift:1192                                                                                                                          │
│ - Panes/BrowserPane.swift:93,94,117,120                                                                                                                   │
│ - Shared/ToastOverlay.swift:30,36                                                                                                                         │
│ - Core/AppUpdateCoordinator.swift:150,169                                                                                                                 │
│ - Core/Workspace.swift:98,115                                                                                                                             │
│                                                                                                                                                           │
│ 1H. GeometryReader → review for modern alternatives                                                                                                       │
│                                                                                                                                                           │
│ 2 occurrences:                                                                                                                                            │
│ - Panes/TaskBoardPane.swift:260 — adaptive layout; consider ViewThatFits or Layout protocol                                                               │
│ - Panes/BrowserPane.swift:427 — progress bar width; consider containerRelativeFrame()                                                                     │
│                                                                                                                                                           │
│ ---                                                                                                                                                       │
│ Phase 2: Data Flow Modernization (@Observable Migration)                                                                                                  │
│                                                                                                                                                           │
│ This is the highest-impact change in the entire plan. The codebase uses the pre-iOS 17 ObservableObject/@Published/@StateObject/@ObservedObject pattern   │
│ exclusively. Modern SwiftUI uses @Observable/@State/@Bindable/@Environment.                                                                               │
│                                                                                                                                                           │
│ Migration strategy (incremental, one class at a time):                                                                                                    │
│                                                                                                                                                           │
│ 1. Replace class Foo: ObservableObject with @Observable @MainActor final class Foo                                                                        │
│ 2. Remove all @Published wrappers (properties become plain var)                                                                                           │
│ 3. Replace @StateObject private var vm = Foo() with @State private var vm = Foo()                                                                         │
│ 4. Replace @ObservedObject var vm: Foo with var vm: Foo (or @Bindable var vm: Foo if bindings needed)                                                     │
│ 5. Remove import Combine if no longer needed                                                                                                              │
│ 6. For theme: after Phase 0C, replace @ObservedObject private var theme = GhosttyThemeProvider.shared with @Environment(GhosttyThemeProvider.self) var    │
│ theme                                                                                                                                                     │
│                                                                                                                                                           │
│ Classes to migrate (25 total):                                                                                                                            │
│                                                                                                                                                           │
│ Core/shared (migrate first — other classes depend on these):                                                                                              │
│                                                                                                                                                           │
│ ┌──────────────────────┬─────────────────────────────────────┬──────────────────┐                                                                         │
│ │        Class         │                File                 │ @Published count │                                                                         │
│ ├──────────────────────┼─────────────────────────────────────┼──────────────────┤                                                                         │
│ │ GhosttyThemeProvider │ Terminal/GhosttyThemeProvider.swift │ 5                │                                                                         │
│ ├──────────────────────┼─────────────────────────────────────┼──────────────────┤                                                                         │
│ │ WorkspaceManager     │ Core/WorkspaceManager.swift         │ 2                │                                                                         │
│ ├──────────────────────┼─────────────────────────────────────┼──────────────────┤                                                                         │
│ │ Workspace            │ Core/Workspace.swift                │ 16               │                                                                         │
│ ├──────────────────────┼─────────────────────────────────────┼──────────────────┤                                                                         │
│ │ SessionStore         │ Core/SessionStore.swift             │ 5                │                                                                         │
│ ├──────────────────────┼─────────────────────────────────────┼──────────────────┤                                                                         │
│ │ ToastManager         │ Shared/ToastOverlay.swift           │ 1                │                                                                         │
│ ├──────────────────────┼─────────────────────────────────────┼──────────────────┤                                                                         │
│ │ AppUpdateCoordinator │ Core/AppUpdateCoordinator.swift     │ 1                │                                                                         │
│ └──────────────────────┴─────────────────────────────────────┴──────────────────┘                                                                         │
│                                                                                                                                                           │
│ Pane ViewModels (migrate second — each is self-contained):                                                                                                │
│                                                                                                                                                           │
│ ┌──────────────────────────────┬─────────────────────────────────────────────┐                                                                            │
│ │            Class             │                    File                     │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ TaskBoardViewModel           │ Panes/TaskBoardPane.swift                   │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ WorkflowViewModel            │ Panes/WorkflowPane.swift                    │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ AgentViewModel               │ Panes/WorkflowPane.swift                    │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ ReviewViewModel              │ Panes/ReviewPane.swift                      │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ ReplayViewModel              │ Panes/ReplayPane.swift                      │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ DiffViewModel                │ Panes/DiffPane.swift                        │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ AnalyticsViewModel           │ Panes/AnalyticsPane.swift                   │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ SearchViewModel              │ Panes/SearchPane.swift                      │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ NotificationsViewModel       │ Panes/NotificationsPane.swift               │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ FileBrowserViewModel         │ Panes/FileBrowserPane.swift                 │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ MergeQueueViewModel          │ Panes/MergeQueuePane.swift                  │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ DailyBriefViewModel          │ Panes/DailyBriefPane.swift                  │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ SshManagerViewModel          │ Panes/SshManagerPane.swift                  │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ RulesManagerViewModel        │ Panes/RulesManagerPane.swift                │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ BrowserViewModel             │ Panes/BrowserPane.swift                     │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ BrowserFindState             │ Panes/BrowserFind.swift                     │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ BrowserReaderState           │ Panes/BrowserMarkdown.swift                 │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ SettingsViewModel            │ Panes/SettingsPane.swift                    │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ GhosttySettingsViewModel     │ Terminal/GhosttySettingsViewModel.swift     │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ GhosttyThemeBrowserViewModel │ Terminal/GhosttyThemeBrowserViewModel.swift │                                                                            │
│ ├──────────────────────────────┼─────────────────────────────────────────────┤                                                                            │
│ │ OnboardingViewModel          │ Chrome/OnboardingFlow.swift                 │                                                                            │
│ └──────────────────────────────┴─────────────────────────────────────────────┘                                                                            │
│                                                                                                                                                           │
│ Note: GhosttyThemeProvider uses NotificationCenter observers internally — the @Observable migration only changes the external API. The internal           │
│ observation of Ghostty notifications via addObserver stays as-is.                                                                                         │
│                                                                                                                                                           │
│ ---                                                                                                                                                       │
│ Phase 3: View Composition & File Structure                                                                                                                │
│                                                                                                                                                           │
│ 3A. Split oversized files (one type per file)                                                                                                             │
│                                                                                                                                                           │
│ Critical — WorkflowPane.swift (1916 lines, 24 types):                                                                                                     │
│ Split into:                                                                                                                                               │
│ - Panes/Workflow/WorkflowModels.swift — data models (WorkflowDefItem, LoopMode, LoopConfig, WorkflowStepDef, WorkflowInstanceItem,                        │
│ WorkflowInstanceDetail, WorkflowInstanceStepItem, AgentProfileItem, AgentProfileFullItem, OrchestrationScope)                                             │
│ - Panes/Workflow/WorkflowViewModel.swift — WorkflowViewModel + AgentViewModel                                                                             │
│ - Panes/Workflow/WorkflowView.swift — main WorkflowView, LibrarySection, ActiveSection                                                                    │
│ - Panes/Workflow/WorkflowInstanceView.swift — InstanceDetailView, InstanceStepNode                                                                        │
│ - Panes/Workflow/WorkflowBuilderView.swift — BuilderSection, FormBuilder, StepFormCard, MiniDagPreview                                                    │
│ - Panes/Workflow/WorkflowAgentsView.swift — AgentsSection, AgentRow, AgentFormCard                                                                        │
│ - Panes/Workflow/WorkflowComponents.swift — StatusBadge, RoleBadge                                                                                        │
│ - Panes/Workflow/WorkflowPane.swift — PaneContent wrapper only                                                                                            │
│                                                                                                                                                           │
│ High — BrowserPane.swift (8 types):                                                                                                                       │
│ Split into:                                                                                                                                               │
│ - Panes/Browser/BrowserModels.swift — PnevmaWebView, BrowserSearchEngine, BrowserHistoryStore                                                             │
│ - Panes/Browser/BrowserViewModel.swift                                                                                                                    │
│ - Panes/Browser/BrowserView.swift — main view                                                                                                             │
│ - Panes/Browser/BrowserOmnibar.swift — OmnibarTextField (NSViewRepresentable)                                                                             │
│ - Panes/Browser/WebViewRepresentable.swift                                                                                                                │
│ - Panes/Browser/BrowserPane.swift — wrapper                                                                                                               │
│                                                                                                                                                           │
│ High — SidebarView.swift (6+ types):                                                                                                                      │
│ Split into:                                                                                                                                               │
│ - Sidebar/SidebarView.swift — main view only                                                                                                              │
│ - Sidebar/SidebarToolButton.swift                                                                                                                         │
│ - Sidebar/WorkspaceRow.swift                                                                                                                              │
│ - Sidebar/SidebarComponents.swift — AddButton, CloseButton, ToolsSectionHeader, NotificationBadge                                                         │
│ - Sidebar/SidebarToolItem.swift — model + sidebarTools array                                                                                              │
│                                                                                                                                                           │
│ Medium — remaining pane files with 5+ types:                                                                                                              │
│ - SettingsPane.swift — extract each tab into its own file under Panes/Settings/                                                                           │
│ - TaskBoardPane.swift — extract models to TaskBoardModels.swift, viewmodel to TaskBoardViewModel.swift                                                    │
│ - DiffPane.swift — extract models + viewmodel                                                                                                             │
│ - SshManagerPane.swift — extract models + viewmodel + AddSheet                                                                                            │
│ - DailyBriefPane.swift — extract models + viewmodel                                                                                                       │
│ - NotificationsPane.swift — extract NotificationItem + viewmodel + NotificationRow                                                                        │
│ - SessionManagerView.swift — extract SessionRow, EmptyState                                                                                               │
│                                                                                                                                                           │
│ 3B. Extract oversized body properties into subviews                                                                                                       │
│                                                                                                                                                           │
│ ┌───────────────────────────────────────────┬────────────┬─────────────────────────────────────────────────────────────────────────────────────┐          │
│ │                   File                    │ body lines │                                     Extract to                                      │          │
│ ├───────────────────────────────────────────┼────────────┼─────────────────────────────────────────────────────────────────────────────────────┤          │
│ │ BrowserPane.swift (BrowserView)           │ ~285       │ OmnibarView, SuggestionsDropdownView, NewTabPageView                                │          │
│ ├───────────────────────────────────────────┼────────────┼─────────────────────────────────────────────────────────────────────────────────────┤          │
│ │ ReviewPane.swift (detailPanel)            │ ~87        │ ReviewDetailPanel struct                                                            │          │
│ ├───────────────────────────────────────────┼────────────┼─────────────────────────────────────────────────────────────────────────────────────┤          │
│ │ AnalyticsPane.swift (analyticsContent)    │ ~123       │ CostOverviewChart, ModelComparisonChart, ProviderBreakdownPanel, ErrorHotspotsPanel │          │
│ ├───────────────────────────────────────────┼────────────┼─────────────────────────────────────────────────────────────────────────────────────┤          │
│ │ DiffPane.swift                            │ ~125       │ DiffHeaderView, DiffContentView                                                     │          │
│ ├───────────────────────────────────────────┼────────────┼─────────────────────────────────────────────────────────────────────────────────────┤          │
│ │ PaneProtocol.swift (PaneDefaultEmptyView) │ ~82        │ WelcomeIllustration, WelcomeActions                                                 │          │
│ └───────────────────────────────────────────┴────────────┴─────────────────────────────────────────────────────────────────────────────────────┘          │
│                                                                                                                                                           │
│ 3C. Replace .onAppear with .task() for async work                                                                                                         │
│                                                                                                                                                           │
│ Pattern across 14+ pane files: All use .onAppear { viewModel.activate() } where activate() triggers async network/backend calls. Replace with .task {     │
│ await viewModel.activate() } for proper lifecycle management (auto-cancellation on disappear).                                                            │
│                                                                                                                                                           │
│ Files: SearchPane, RulesManagerPane, WorkflowPane, DiffPane, AnalyticsPane, BrowserPane, GhosttyThemeBrowserSheet, ReviewPane, NotificationsPane,         │
│ DailyBriefPane, MergeQueuePane, FileBrowserPane, TaskBoardPane, ReplayPane.                                                                               │
│                                                                                                                                                           │
│ ---                                                                                                                                                       │
│ Phase 4: Swift Concurrency Modernization                                                                                                                  │
│                                                                                                                                                           │
│ 4A. Replace DispatchQueue with structured concurrency                                                                                                     │
│                                                                                                                                                           │
│ 16 occurrences across 6 files:                                                                                                                            │
│                                                                                                                                                           │
│ ┌─────────────────────────────────┬──────────────────────┬────────────────────────────────────────────┬────────────────────────────────────────────────┐  │
│ │              File               │        Lines         │                  Pattern                   │                  Replacement                   │  │
│ ├─────────────────────────────────┼──────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────┤  │
│ │ App/AppDelegate.swift           │ 150, 427, 441, 471,  │ DispatchQueue.global(), .main.async,       │ Task { }, Task { @MainActor in }, Task { try?  │  │
│ │                                 │ 831                  │ .main.asyncAfter                           │ await Task.sleep(for:) }                       │  │
│ ├─────────────────────────────────┼──────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────┤  │
│ │ Bridge/PnevmaBridge.swift       │ 57, 163              │ DispatchQueue.main.async                   │ Task { @MainActor in }                         │  │
│ ├─────────────────────────────────┼──────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────┤  │
│ │ Core/ContentAreaView.swift      │ 607, 922             │ DispatchQueue.main.asyncAfter              │ Task { try? await Task.sleep(for:); ... }      │  │
│ ├─────────────────────────────────┼──────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────┤  │
│ │ Terminal/TerminalHostView.swift │ 447                  │ DispatchQueue.main.async { [weak self] in  │ Task { @MainActor [weak self] in }             │  │
│ ├─────────────────────────────────┼──────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────┤  │
│ │ Terminal/TerminalSurface.swift  │ 85, 111, 442, 459,   │ DispatchQueue.main.async                   │ Task { @MainActor in }                         │  │
│ │                                 │ 472, 483, 493        │                                            │                                                │  │
│ ├─────────────────────────────────┼──────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────┤  │
│ │ Panes/BrowserPane.swift         │ 820                  │ DispatchQueue.main.async { [weak self] in  │ Task { @MainActor [weak self] in }             │  │
│ └─────────────────────────────────┴──────────────────────┴────────────────────────────────────────────┴────────────────────────────────────────────────┘  │
│                                                                                                                                                           │
│ 4B. Audit force unwraps                                                                                                                                   │
│                                                                                                                                                           │
│ 23 occurrences across 7 files — fix the risky ones:                                                                                                       │
│                                                                                                                                                           │
│ ┌──────────┬────────────────────────────────────────┬───────────┬──────────────────────────────────────────────────────────────────────┐                  │
│ │ Priority │                  File                  │   Lines   │                                 Fix                                  │                  │
│ ├──────────┼────────────────────────────────────────┼───────────┼──────────────────────────────────────────────────────────────────────┤                  │
│ │ HIGH     │ WorkflowPane.swift                     │ 1330-1407 │ 11 currentStep! — guard let before use                               │                  │
│ ├──────────┼────────────────────────────────────────┼───────────┼──────────────────────────────────────────────────────────────────────┤                  │
│ │ HIGH     │ App/AppDelegate.swift                  │ 333-387   │ 8 contentAreaView!, statusBar! — guard let or restructure init order │                  │
│ ├──────────┼────────────────────────────────────────┼───────────┼──────────────────────────────────────────────────────────────────────┤                  │
│ │ MEDIUM   │ Core/PaneLayoutEngine.swift            │ 437       │ best!.1 — use guard let                                              │                  │
│ ├──────────┼────────────────────────────────────────┼───────────┼──────────────────────────────────────────────────────────────────────┤                  │
│ │ MEDIUM   │ Terminal/GhosttyConfigController.swift │ 521       │ firstIndex(of: "=")! — guard let                                     │                  │
│ ├──────────┼────────────────────────────────────────┼───────────┼──────────────────────────────────────────────────────────────────────┤                  │
│ │ LOW      │ Core/AppUpdateCoordinator.swift        │ 15        │ URL(string: "...")! — compile-time constant, acceptable              │                  │
│ └──────────┴────────────────────────────────────────┴───────────┴──────────────────────────────────────────────────────────────────────┘                  │
│                                                                                                                                                           │
│ ---                                                                                                                                                       │
│ Phase 5: Accessibility Depth                                                                                                                              │
│                                                                                                                                                           │
│ Extends uiux_plan.md Group D with swiftui-pro-specific findings.                                                                                          │
│                                                                                                                                                           │
│ 5A. Add .accessibilityAddTraits(.isButton) to all onTapGesture elements                                                                                   │
│                                                                                                                                                           │
│ 5+ locations:                                                                                                                                             │
│ - Sidebar/SidebarView.swift:318 — WorkspaceRow tap                                                                                                        │
│ - Shared/ToastOverlay.swift — toast dismiss tap                                                                                                           │
│ - Panes/GhosttyThemeBrowserSheet.swift — theme selection tap                                                                                              │
│ - Panes/NotificationsPane.swift:81 — notification mark-read tap                                                                                           │
│ - Panes/FileBrowserPane.swift — file selection tap                                                                                                        │
│                                                                                                                                                           │
│ 5B. Add accessibility labels to unlabeled interactive elements                                                                                            │
│                                                                                                                                                           │
│ - Chrome/SessionManagerView.swift:31-33 — refresh/kill buttons missing labels                                                                             │
│ - Panes/BrowserPane.swift:510-532 — back/forward/reload buttons missing labels                                                                            │
│ - Panes/NotificationsPane.swift:114 — notification status icon missing label                                                                              │
│                                                                                                                                                           │
│ 5C. Mark decorative images as hidden                                                                                                                      │
│                                                                                                                                                           │
│ - Chrome/OnboardingFlow.swift:20 — terminal header icon → .accessibilityHidden(true)                                                                      │
│ - Panes/BrowserPane.swift:648 — globe icon in new tab page → .accessibilityHidden(true)                                                                   │
│                                                                                                                                                           │
│ 5D. Replace hard-coded font sizes with semantic Dynamic Type                                                                                              │
│                                                                                                                                                           │
│ 40+ instances of .font(.system(size: X)) across the codebase. Key locations:                                                                              │
│ - Sidebar/SidebarView.swift — lines 78, 168, 293, 419, 424 (sizes 9, 10, 11)                                                                              │
│ - All pane views with manual sizes                                                                                                                        │
│                                                                                                                                                           │
│ Migration: .system(size: 11) → .caption, .system(size: 13) → .body, .system(size: 9) → .caption2 (flag for review — may be too small per WCAG).           │
│                                                                                                                                                           │
│ 5E. Review .caption2 usage for WCAG compliance                                                                                                            │
│                                                                                                                                                           │
│ 10+ instances across SidebarView, SettingsPane, NotificationsPane, DailyBriefPane. The .caption2 size (10pt) may be below WCAG 2.1 AA minimums. Upgrade   │
│ to .caption (11pt) where the text conveys essential information.                                                                                          │
│                                                                                                                                                           │
│ ---                                                                                                                                                       │
│ Phase 6: Design & Performance Polish                                                                                                                      │
│                                                                                                                                                           │
│ 6A. Use ContentUnavailableView for empty states (macOS 14+)                                                                                               │
│                                                                                                                                                           │
│ - Chrome/SessionManagerView.swift — custom empty state → ContentUnavailableView                                                                           │
│ - Panes/NotificationsPane.swift — custom EmptyStateView → ContentUnavailableView                                                                          │
│ - Panes/ReviewPane.swift:86-92 — manual VStack → ContentUnavailableView                                                                                   │
│                                                                                                                                                           │
│ 6B. Use Label instead of HStack { Image; Text }                                                                                                           │
│                                                                                                                                                           │
│ - Sidebar/SidebarView.swift:157-164 — SidebarToolButton layout → Label(tool.title, systemImage: tool.icon)                                                │
│                                                                                                                                                           │
│ 6C. Use .bold() instead of .fontWeight(.bold)                                                                                                             │
│                                                                                                                                                           │
│ - Sidebar/SidebarView.swift — multiple instances of .fontWeight(.semibold) / .fontWeight(.bold)                                                           │
│                                                                                                                                                           │
│ 6D. Use sheet(item:) instead of sheet(isPresented:) where optional data exists                                                                            │
│                                                                                                                                                           │
│ - Panes/SshManagerPane.swift:75                                                                                                                           │
│ - Panes/RulesManagerPane.swift:88                                                                                                                         │
│ - Panes/TaskBoardPane.swift:330                                                                                                                           │
│ - Panes/SettingsPane.swift:255,258                                                                                                                        │
│                                                                                                                                                           │
│ 6E. Prefer ternary for modifier toggling over if/else branching                                                                                           │
│                                                                                                                                                           │
│ - Sidebar/SidebarView.swift:228-237 — pin icon/circle indicator uses if/else for different views                                                          │
│                                                                                                                                                           │
│ 6F. Cache sorting/filtering outside body                                                                                                                  │
│                                                                                                                                                           │
│ - Panes/BrowserPane.swift:663-665 — newTabPage sorts history on every render; move to viewmodel                                                           │
│                                                                                                                                                           │
│ ---                                                                                                                                                       │
│ Execution Order                                                                                                                                           │
│                                                                                                                                                           │
│ Phase 0  (Infrastructure)     — 0C environment injection                                                                                                  │
│ Phase 1  (API Modernization)  — mechanical find-replace, low risk                                                                                         │
│ Phase 2  (Data Flow)          — highest impact, do incrementally                                                                                          │
│ Phase 3  (View Composition)   — file splits + body extraction                                                                                             │
│ Phase 4  (Concurrency)        — DispatchQueue → async/await                                                                                               │
│ Phase 5  (Accessibility)      — traits, labels, dynamic type                                                                                              │
│ Phase 6  (Design/Performance) — ContentUnavailableView, polish                                                                                            │
│                                                                                                                                                           │
│ Phases 1, 4, 5, and 6 can be parallelized. Phase 2 should happen after Phase 0C. Phase 3 can happen any time but is easier after Phase 2 (fewer merge     │
│ conflicts).                                                                                                                                               │
│                                                                                                                                                           │
│ ---                                                                                                                                                       │
│ Verification                                                                                                                                              │
│                                                                                                                                                           │
│ After each phase:                                                                                                                                         │
│                                                                                                                                                           │
│ 1. just xcode-build — must compile clean with zero warnings                                                                                               │
│ 2. Launch app and visually verify affected areas:                                                                                                         │
│   - Phase 1: WorkflowPane renders correctly, scroll views work, dates/currency display properly                                                           │
│   - Phase 2: All pane viewmodels still update UI reactively; verify sidebar, toast, settings                                                              │
│   - Phase 3: All panes still open correctly; no missing views after file splits                                                                           │
│   - Phase 4: Bridge events still dispatch; terminal surface still renders; no race conditions                                                             │
│   - Phase 5: VoiceOver navigation through sidebar, tabs, browser omnibar; Reduce Motion ON test                                                           │
│   - Phase 6: Empty states render; theme colors propagate through environment                                                                              │
│ 3. VoiceOver spot check: navigate each modified pane                                                                                                      │
│ 4. Accessibility Inspector: run on main window to catch missing labels                                                                                    │
│ 5. System Preferences → Reduce Motion ON → verify all animations respect setting                                                                          │
│                                                                                                                                                           │
│ ---                                                                                                                                                       │
│ Files Changed (Summary)                                                                                                                                   │
│                                                                                                                                                           │
│ ┌───────┬────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┬─────────────────┐  │
│ │ Phase │                                                           Files                                                            │  Est. Changes   │  │
│ ├───────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────┤  │
│ │ 0     │ Extensions.swift, AppDelegate.swift, ToastOverlay.swift, OnboardingFlow.swift                                              │ 4 files         │  │
│ ├───────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────┤  │
│ │       │ WorkflowPane, TaskBoardPane, SidebarView, BrowserPane, BrowserFind, SettingsPane, ToastOverlay, DailyBriefPane,            │                 │  │
│ │ 1     │ BrowserMarkdown, GhosttyConfigController, GhosttySettingsViewModel, ReplayPane, AnalyticsPane, ReviewPane, Workspace,      │ 17 files        │  │
│ │       │ AppUpdateCoordinator, TerminalConfig                                                                                       │                 │  │
│ ├───────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────┤  │
│ │ 2     │ All 25 ObservableObject classes + their consuming views                                                                    │ ~30 files       │  │
│ ├───────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────┤  │
│ │ 3     │ WorkflowPane (split to 8), BrowserPane (split to 6), SidebarView (split to 5), + 8 other pane splits                       │ ~40 new files,  │  │
│ │       │                                                                                                                            │ ~15 modified    │  │
│ ├───────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────┤  │
│ │ 4     │ AppDelegate, PnevmaBridge, ContentAreaView, TerminalHostView, TerminalSurface, BrowserPane, WorkflowPane,                  │ 9 files         │  │
│ │       │ PaneLayoutEngine, GhosttyConfigController                                                                                  │                 │  │
│ ├───────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────┤  │
│ │ 5     │ SidebarView, ToastOverlay, GhosttyThemeBrowserSheet, NotificationsPane, FileBrowserPane, SessionManagerView, BrowserPane,  │ 8 files         │  │
│ │       │ OnboardingFlow                                                                                                             │                 │  │
│ ├───────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────┤  │
│ │ 6     │ SessionManagerView, NotificationsPane, ReviewPane, SidebarView, SshManagerPane, RulesManagerPane, TaskBoardPane,           │ 9 files         │  │
│ │       │ SettingsPane, BrowserPane                                                                                                  │                 │  │
│ └───────┴────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┴─────────────────┘  │