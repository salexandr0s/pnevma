import Observation
import SwiftUI

@Observable @MainActor
final class BrowserDrawerChromeState {
    var isPresented = false
    var drawerHitRect: CGRect = .zero
}

private struct BrowserDrawerFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

struct BrowserDrawerOverlayView: View {
    @Environment(GhosttyThemeProvider.self) private var theme
    @Bindable var chromeState: BrowserDrawerChromeState
    let session: BrowserWorkspaceSession?
    let onClose: () -> Void
    let onPinToPane: () -> Void
    let onOpenAsTab: () -> Void
    let onVisibilityChanged: (Bool) -> Void
    let onHitRectChanged: (CGRect) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if chromeState.isPresented, let session {
                    drawerCard(for: session, in: geometry.size)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: BrowserDrawerFramePreferenceKey.self,
                                    value: proxy.frame(in: .named("browserDrawerOverlaySpace"))
                                )
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
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
                chromeState.drawerHitRect = .zero
                onHitRectChanged(.zero)
            }
            onVisibilityChanged(isVisible)
        }
        .onAppear {
            onVisibilityChanged(chromeState.isPresented)
            onHitRectChanged(chromeState.isPresented ? chromeState.drawerHitRect : .zero)
        }
        .accessibilityIdentifier("browser.drawer.overlay")
    }

    @ViewBuilder
    private func drawerCard(for session: BrowserWorkspaceSession, in size: CGSize) -> some View {
        let drawerHeight = max(320, min(size.height * 0.45, size.height - 24))
        let cardBackgroundOpacity = min(1.0, max(0.96, theme.backgroundOpacity))
        let cardBackgroundColor = Color(nsColor: theme.backgroundColor).opacity(cardBackgroundOpacity)

        VStack(spacing: 0) {
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
            .padding(.vertical, 10)

            Divider()

            BrowserView(viewModel: session.viewModel)
        }
        .frame(maxWidth: .infinity)
        .frame(height: drawerHeight)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: Color.black.opacity(0.18), radius: 20, y: 12)
    }
}
