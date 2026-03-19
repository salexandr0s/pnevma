import Observation
import SwiftUI

// MARK: - Shared bottom drawer state

@Observable @MainActor
final class BottomDrawerChromeState {
    var isPresented = false
    var drawerHitRect: CGRect = .zero
}

@Observable @MainActor
final class BottomDrawerContentModel {
    var activeToolID: String?
    var activeToolTitle: String?
    var activePaneView: (NSView & PaneContent)?
    var activePaneID: PaneID?
    var activeBrowserSession: BrowserWorkspaceSession?
    var drawerHeight: CGFloat?
}

typealias ToolDrawerChromeState = BottomDrawerChromeState
typealias ToolDrawerContentModel = BottomDrawerContentModel

// MARK: - NSView wrapper for pane content

struct PaneContentBridge: NSViewRepresentable {
    let paneView: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        paneView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            paneView.topAnchor.constraint(equalTo: container.topAnchor),
            paneView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.subviews.first === paneView { return }
        nsView.subviews.forEach { $0.removeFromSuperview() }
        paneView.translatesAutoresizingMaskIntoConstraints = false
        nsView.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.leadingAnchor.constraint(equalTo: nsView.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: nsView.trailingAnchor),
            paneView.topAnchor.constraint(equalTo: nsView.topAnchor),
            paneView.bottomAnchor.constraint(equalTo: nsView.bottomAnchor),
        ])
    }
}

// MARK: - Preference key

private struct BottomDrawerFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Overlay view

struct BottomDrawerOverlayView: View {
    @Environment(GhosttyThemeProvider.self) private var theme
    @Bindable var chromeState: BottomDrawerChromeState
    @Bindable var contentModel: BottomDrawerContentModel
    let onClose: () -> Void
    let onPinToPane: () -> Void
    let onOpenAsTab: () -> Void
    let onVisibilityChanged: (Bool) -> Void
    let onHitRectChanged: (CGRect) -> Void

    @State private var isMaximized = false
    @State private var heightBeforeMaximize: CGFloat?

    private var transitionAnimation: Animation? {
        chromeState.isPresented
            ? ChromeMotion.animation(for: .bottomDrawerOpen)
            : ChromeMotion.animation(for: .bottomDrawerClose)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if hasActiveContent {
                    drawerCard(in: geometry.size)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: BottomDrawerFramePreferenceKey.self,
                                    value: proxy.frame(in: .named("bottomDrawerOverlaySpace"))
                                )
                            }
                        )
                        .offset(y: chromeState.isPresented ? 0 : ChromeMotion.drawerHiddenOffset(for: geometry.size.height))
                        .opacity(chromeState.isPresented ? 1 : 0)
                        .allowsHitTesting(chromeState.isPresented)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(transitionAnimation, value: chromeState.isPresented)
        }
        .coordinateSpace(name: "bottomDrawerOverlaySpace")
        .allowsHitTesting(chromeState.isPresented)
        .onPreferenceChange(BottomDrawerFramePreferenceKey.self) { rect in
            let resolvedRect = chromeState.isPresented ? rect : .zero
            chromeState.drawerHitRect = resolvedRect
            onHitRectChanged(resolvedRect)
        }
        .onChange(of: chromeState.isPresented) { _, isVisible in
            if !isVisible {
                chromeState.drawerHitRect = .zero
                onHitRectChanged(.zero)
            }
            onVisibilityChanged(isVisible)
        }
        .onAppear {
            onVisibilityChanged(chromeState.isPresented)
            onHitRectChanged(chromeState.isPresented ? chromeState.drawerHitRect : .zero)
        }
    }

    private var hasActiveContent: Bool {
        contentModel.activePaneView != nil || contentModel.activeBrowserSession != nil
    }

    private var drawerTitle: String {
        if let session = contentModel.activeBrowserSession {
            return session.viewModel.pageTitle.isEmpty ? "Browser" : session.viewModel.pageTitle
        }
        return contentModel.activeToolTitle ?? "Tool"
    }

    private var drawerSubtitle: String? {
        contentModel.activeBrowserSession?.currentURL?.host(percentEncoded: false)
    }

    @ViewBuilder
    private func drawerCard(in size: CGSize) -> some View {
        let effectiveHeight = resolvedDrawerHeight(for: size.height)
        let maxDrawerHeight = DrawerSizing.maxHeight(for: size.height)
        let cardBackgroundColor = Color(nsColor: theme.backgroundColor)

        VStack(spacing: 0) {
            DrawerResizeHandle(
                currentHeight: effectiveHeight,
                availableHeight: size.height,
                onHeightChanged: { newHeight in
                    if let session = contentModel.activeBrowserSession {
                        session.setDrawerHeight(newHeight)
                    } else {
                        contentModel.drawerHeight = newHeight
                        DrawerSizing.setStoredHeight(newHeight)
                    }
                    isMaximized = false
                }
            )
            .padding(.top, 8)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(drawerTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if let drawerSubtitle {
                        Text(drawerSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button(action: {
                    if isMaximized {
                        let restored = heightBeforeMaximize ?? effectiveHeight
                        applyDrawerHeight(restored)
                        isMaximized = false
                    } else {
                        heightBeforeMaximize = effectiveHeight
                        applyDrawerHeight(maxDrawerHeight)
                        isMaximized = true
                    }
                }) {
                    Image(systemName: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isMaximized ? "Restore drawer" : "Maximize drawer")

                Button("Open as Tab", action: onOpenAsTab)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("bottom.drawer.openAsTab")

                Button("Pin as Pane", action: onPinToPane)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("bottom.drawer.pinAsPane")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close drawer")
                .accessibilityIdentifier("bottom.drawer.close")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            if chromeState.isPresented, let session = contentModel.activeBrowserSession {
                BrowserView(session: session)
                    .id(session.workspaceID)
            } else if chromeState.isPresented, let paneView = contentModel.activePaneView {
                PaneContentBridge(paneView: paneView)
                    .id(contentModel.activePaneID)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: effectiveHeight)
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

    private func resolvedDrawerHeight(for availableHeight: CGFloat) -> CGFloat {
        if let session = contentModel.activeBrowserSession {
            return session.resolvedDrawerHeight(for: availableHeight)
        }

        return DrawerSizing.clamp(
            contentModel.drawerHeight
                ?? DrawerSizing.resolvedHeight(availableHeight: availableHeight),
            availableHeight: availableHeight
        )
    }

    private func applyDrawerHeight(_ height: CGFloat) {
        if let session = contentModel.activeBrowserSession {
            session.setDrawerHeight(height)
        } else {
            contentModel.drawerHeight = height
            DrawerSizing.setStoredHeight(height)
        }
    }
}

typealias ToolDrawerOverlayView = BottomDrawerOverlayView

// MARK: - Overlay hosting views

final class BottomDrawerOverlayBlockerView: NSView {
    override var isFlipped: Bool { true }
    var capturesPointerEvents = false
    var overlayHitRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class BottomDrawerOverlayHostingView<Content: View>: FirstMouseHostingView<Content> {
    var capturesPointerEvents = false
    var overlayHitRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard capturesPointerEvents else { return nil }
        return super.hitTest(point)
    }
}

typealias ToolDrawerOverlayBlockerView = BottomDrawerOverlayBlockerView
typealias ToolDrawerOverlayHostingView<Content: View> = BottomDrawerOverlayHostingView<Content>
