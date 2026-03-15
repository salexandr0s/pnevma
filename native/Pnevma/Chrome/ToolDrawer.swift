import Observation
import SwiftUI

// MARK: - Sizing

enum ToolDrawerSizing {
    static let minHeight: CGFloat = 280
    static let verticalInset: CGFloat = 24
    static let defaultHeightRatio: CGFloat = 0.45
    static let keyboardStep: CGFloat = 72

    static func maxHeight(for availableHeight: CGFloat) -> CGFloat {
        max(minHeight, availableHeight - verticalInset)
    }

    static func defaultHeight(for availableHeight: CGFloat) -> CGFloat {
        clamp(availableHeight * defaultHeightRatio, availableHeight: availableHeight)
    }

    static func clamp(_ height: CGFloat, availableHeight: CGFloat) -> CGFloat {
        min(max(height, minHeight), maxHeight(for: availableHeight))
    }

    static func storedHeight() -> CGFloat? {
        let raw = UserDefaults.standard.double(forKey: "toolDrawerHeight")
        return raw > 0 ? raw : nil
    }

    static func setStoredHeight(_ height: CGFloat) {
        UserDefaults.standard.set(height, forKey: "toolDrawerHeight")
    }

    static func resolvedHeight(availableHeight: CGFloat) -> CGFloat {
        clamp(storedHeight() ?? defaultHeight(for: availableHeight), availableHeight: availableHeight)
    }
}

// MARK: - State

@Observable @MainActor
final class ToolDrawerChromeState {
    var isPresented = false
    var drawerHitRect: CGRect = .zero
}

@Observable @MainActor
final class ToolDrawerContentModel {
    var activeToolID: String?
    var activeToolTitle: String?
    var activePaneView: (NSView & PaneContent)?
    var activePaneID: PaneID?
    var drawerHeight: CGFloat?
}

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

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        for subview in nsView.subviews {
            subview.removeFromSuperview()
        }
    }
}

// MARK: - Resize handle

private struct ToolDrawerResizeHandle: View {
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
        .onHover { hovering in
            if hovering {
                NSCursor.openHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartHeight == nil {
                        NSCursor.pop()
                        NSCursor.closedHand.push()
                        dragStartHeight = currentHeight
                    }
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        onHeightChanged(
                            ToolDrawerSizing.clamp(
                                dragStartHeight! - value.translation.height,
                                availableHeight: availableHeight
                            )
                        )
                    }
                }
                .onEnded { _ in
                    NSCursor.pop()
                    NSCursor.openHand.push()
                    dragStartHeight = nil
                }
        )
        .help("Drag to resize")
        .accessibilityLabel("Resize tool drawer")
    }
}

// MARK: - Preference key

private struct ToolDrawerFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Overlay view

struct ToolDrawerOverlayView: View {
    @Environment(GhosttyThemeProvider.self) private var theme
    @Bindable var chromeState: ToolDrawerChromeState
    @Bindable var contentModel: ToolDrawerContentModel
    let onClose: () -> Void
    let onPinToPane: () -> Void
    let onOpenAsTab: () -> Void
    let onVisibilityChanged: (Bool) -> Void
    let onHitRectChanged: (CGRect) -> Void

    @State private var isMaximized = false
    @State private var heightBeforeMaximize: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if contentModel.activePaneView != nil {
                    drawerCard(in: geometry.size)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ToolDrawerFramePreferenceKey.self,
                                    value: proxy.frame(in: .named("toolDrawerOverlaySpace"))
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
        .coordinateSpace(name: "toolDrawerOverlaySpace")
        .allowsHitTesting(chromeState.isPresented)
        .onPreferenceChange(ToolDrawerFramePreferenceKey.self) { rect in
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
        .accessibilityIdentifier("tool.drawer.overlay")
    }

    @ViewBuilder
    private func drawerCard(in size: CGSize) -> some View {
        let drawerHeight = ToolDrawerSizing.resolvedHeight(availableHeight: size.height)
        let maxDrawerHeight = ToolDrawerSizing.maxHeight(for: size.height)
        let cardBackgroundColor = Color(nsColor: theme.backgroundColor)

        VStack(spacing: 0) {
            ToolDrawerResizeHandle(
                currentHeight: contentModel.drawerHeight ?? drawerHeight,
                availableHeight: size.height,
                onHeightChanged: { newHeight in
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        contentModel.drawerHeight = newHeight
                    }
                    ToolDrawerSizing.setStoredHeight(newHeight)
                    isMaximized = false
                }
            )
            .padding(.top, 8)

            HStack(spacing: 8) {
                Text(contentModel.activeToolTitle ?? "Tool")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                Button(action: {
                    let current = contentModel.drawerHeight ?? drawerHeight
                    if isMaximized {
                        contentModel.drawerHeight = heightBeforeMaximize
                        ToolDrawerSizing.setStoredHeight(heightBeforeMaximize ?? drawerHeight)
                        isMaximized = false
                    } else {
                        heightBeforeMaximize = current
                        contentModel.drawerHeight = maxDrawerHeight
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

                Button("Pin as Pane", action: onPinToPane)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close drawer")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            if chromeState.isPresented, let paneView = contentModel.activePaneView {
                PaneContentBridge(paneView: paneView)
                    .id(contentModel.activePaneID)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: contentModel.drawerHeight ?? drawerHeight)
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

// MARK: - Overlay hosting views (same pattern as browser drawer)

final class ToolDrawerOverlayBlockerView: NSView {
    override var isFlipped: Bool { true }
    var capturesPointerEvents = false
    var overlayHitRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class ToolDrawerOverlayHostingView<Content: View>: NSHostingView<Content> {
    var capturesPointerEvents = false
    var overlayHitRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard capturesPointerEvents else { return nil }
        return super.hitTest(point)
    }
}
