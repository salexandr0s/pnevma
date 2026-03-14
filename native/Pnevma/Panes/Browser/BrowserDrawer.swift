import Observation
import os
import SwiftUI

enum BrowserDrawerSizing {
    static let minHeight: CGFloat = 320
    static let verticalInset: CGFloat = 24
    static let defaultHeightRatio: CGFloat = 0.45
    static let keyboardStep: CGFloat = 72

    static func maxHeight(for availableHeight: CGFloat) -> CGFloat {
        max(minHeight, availableHeight - verticalInset)
    }

    static func defaultHeight(for availableHeight: CGFloat) -> CGFloat {
        clamp(availableHeight * defaultHeightRatio, availableHeight: availableHeight)
    }

    static func resolvedHeight(storedHeight: CGFloat?, availableHeight: CGFloat) -> CGFloat {
        clamp(storedHeight ?? defaultHeight(for: availableHeight), availableHeight: availableHeight)
    }

    static func clamp(_ height: CGFloat, availableHeight: CGFloat) -> CGFloat {
        min(max(height, minHeight), maxHeight(for: availableHeight))
    }
}

@Observable @MainActor
final class BrowserDrawerChromeState {
    var isPresented = false
    var drawerHitRect: CGRect = .zero
}

@Observable @MainActor
final class BrowserDrawerPresentationModel {
    var session: BrowserWorkspaceSession?
}

private struct BrowserDrawerFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct BrowserDrawerResizeHandle: View {
    let currentHeight: CGFloat
    let availableHeight: CGFloat
    let onHeightChanged: (CGFloat) -> Void

    @State private var dragStartHeight: CGFloat?

    var body: some View {
        ZStack {
            Color.clear
                .frame(height: 18)

            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 46, height: 5)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let baseHeight = dragStartHeight ?? currentHeight
                    if dragStartHeight == nil {
                        dragStartHeight = currentHeight
                    }
                    onHeightChanged(
                        BrowserDrawerSizing.clamp(
                            baseHeight - value.translation.height,
                            availableHeight: availableHeight
                        )
                    )
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
        .help("Drag to resize the browser drawer. Use Option-Command-Equals and Option-Command-Minus to resize it from the keyboard.")
        .accessibilityLabel("Resize browser drawer")
    }
}

struct BrowserDrawerOverlayView: View {
    @Environment(GhosttyThemeProvider.self) private var theme
    @Bindable var chromeState: BrowserDrawerChromeState
    @Bindable var presentationModel: BrowserDrawerPresentationModel
    let onClose: () -> Void
    let onPinToPane: () -> Void
    let onOpenAsTab: () -> Void
    let onVisibilityChanged: (Bool) -> Void
    let onHitRectChanged: (CGRect) -> Void

    @State private var isMaximized = false
    @State private var heightBeforeMaximize: CGFloat?
    @State private var transitionSignpostState: OSSignpostIntervalState?
    @State private var transitionCompletionTask: Task<Void, Never>?
    @State private var transitionGeneration = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if let session = presentationModel.session {
                    drawerCard(for: session, in: geometry.size)
                        .id(session.workspaceID)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: BrowserDrawerFramePreferenceKey.self,
                                    value: proxy.frame(in: .named("browserDrawerOverlaySpace"))
                                )
                            }
                        )
                        .offset(y: chromeState.isPresented ? 0 : geometry.size.height + 24)
                        .opacity(chromeState.isPresented ? 1 : 0)
                        .allowsHitTesting(chromeState.isPresented)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.easeInOut(duration: DesignTokens.Motion.normal), value: chromeState.isPresented)
        }
        .coordinateSpace(name: "browserDrawerOverlaySpace")
        .allowsHitTesting(chromeState.isPresented)
        .onPreferenceChange(BrowserDrawerFramePreferenceKey.self) { rect in
            let resolvedRect = chromeState.isPresented ? rect : .zero
            chromeState.drawerHitRect = resolvedRect
            onHitRectChanged(resolvedRect)
        }
        .onChange(of: chromeState.isPresented) { _, isVisible in
            if !isVisible {
                presentationModel.session?.cancelPendingDrawerRestore()
                chromeState.drawerHitRect = .zero
                onHitRectChanged(.zero)
            } else if let session = presentationModel.session {
                session.scheduleDrawerRestoreIfNeeded(after: .seconds(DesignTokens.Motion.normal))
            }
            if let transitionSignpostState {
                PerformanceDiagnostics.shared.endInterval("browser_drawer.toggle", transitionSignpostState)
                self.transitionSignpostState = nil
            }
            transitionCompletionTask?.cancel()
            transitionGeneration &+= 1
            let generation = transitionGeneration
            let signpost = PerformanceDiagnostics.shared.beginInterval("browser_drawer.toggle")
            transitionSignpostState = signpost
            transitionCompletionTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(DesignTokens.Motion.normal * 1_000)))
                guard !Task.isCancelled,
                      transitionGeneration == generation else { return }
                PerformanceDiagnostics.shared.endInterval("browser_drawer.toggle", signpost)
                transitionSignpostState = nil
            }
            onVisibilityChanged(isVisible)
        }
        .onChange(of: presentationModel.session?.workspaceID) { _, _ in
            isMaximized = false
            heightBeforeMaximize = nil
            if chromeState.isPresented,
               let session = presentationModel.session {
                session.scheduleDrawerRestoreIfNeeded(after: .seconds(DesignTokens.Motion.normal))
            }
        }
        .onAppear {
            onVisibilityChanged(chromeState.isPresented)
            onHitRectChanged(chromeState.isPresented ? chromeState.drawerHitRect : .zero)
        }
        .onDisappear {
            transitionCompletionTask?.cancel()
            if let transitionSignpostState {
                PerformanceDiagnostics.shared.endInterval("browser_drawer.toggle", transitionSignpostState)
                self.transitionSignpostState = nil
            }
        }
        .accessibilityIdentifier("browser.drawer.overlay")
    }

    @ViewBuilder
    private func drawerCard(for session: BrowserWorkspaceSession, in size: CGSize) -> some View {
        let drawerHeight = session.resolvedDrawerHeight(for: size.height)
        let maxDrawerHeight = BrowserDrawerSizing.maxHeight(for: size.height)
        let cardBackgroundColor = Color(nsColor: theme.backgroundColor)

        VStack(spacing: 0) {
            BrowserDrawerResizeHandle(
                currentHeight: drawerHeight,
                availableHeight: size.height,
                onHeightChanged: {
                    session.setDrawerHeight($0)
                    isMaximized = false
                }
            )
            .padding(.top, 8)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.viewModel.pageTitle.isEmpty ? "Browser" : session.viewModel.pageTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(session.currentURL?.host(percentEncoded: false) ?? "Built-in browser")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: {
                    if isMaximized {
                        session.setDrawerHeight(heightBeforeMaximize)
                        isMaximized = false
                    } else {
                        heightBeforeMaximize = session.preferredDrawerHeight
                        session.setDrawerHeight(maxDrawerHeight)
                        isMaximized = true
                    }
                }) {
                    Image(systemName: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isMaximized ? "Restore browser drawer" : "Maximize browser drawer")

                Button("Open as Tab", action: onOpenAsTab)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Pin as Pane", action: onPinToPane)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close browser drawer")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            if chromeState.isPresented {
                BrowserView(session: session)
                    .id(session.workspaceID)
            } else {
                // Keep the drawer chrome mounted while hidden, but avoid attaching the
                // shared WKWebView when a browser pane could already be presenting it.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: drawerHeight)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 16,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 16,
                style: .continuous
            )
            .fill(cardBackgroundColor)
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 16,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 16,
                style: .continuous
            )
            .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: -4)
    }
}
