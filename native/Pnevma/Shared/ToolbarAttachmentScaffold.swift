import SwiftUI

private struct ToolbarAttachmentTitleBlock: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(.headline)
                .bold()

            if let subtitle, subtitle.isEmpty == false {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ToolbarAttachmentScaffold<HeaderActions: View, Content: View, Footer: View>: View {
    private let title: String
    private let subtitle: String?
    private let headerActions: HeaderActions
    private let content: Content
    private let footer: Footer
    private let showsFooter: Bool

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder headerActions: () -> HeaderActions,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.headerActions = headerActions()
        self.content = content()
        self.footer = footer()
        self.showsFooter = true
    }

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder headerActions: () -> HeaderActions,
        @ViewBuilder content: () -> Content
    ) where Footer == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.headerActions = headerActions()
        self.content = content()
        self.footer = EmptyView()
        self.showsFooter = false
    }

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) where HeaderActions == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.headerActions = EmptyView()
        self.content = content()
        self.footer = footer()
        self.showsFooter = true
    }

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) where HeaderActions == EmptyView, Footer == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.headerActions = EmptyView()
        self.content = content()
        self.footer = EmptyView()
        self.showsFooter = false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                ToolbarAttachmentTitleBlock(title: title, subtitle: subtitle)

                Spacer(minLength: DesignTokens.Spacing.sm)

                headerActions
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.top, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.sm + DesignTokens.Spacing.xs)
            .background(ChromeSurfaceStyle.toolbar.color)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(ChromeSurfaceStyle.pane.color)

            if showsFooter {
                Divider()

                footer
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm + DesignTokens.Spacing.xs)
                    .background(ChromeSurfaceStyle.toolbar.color)
            }
        }
        .background(ChromeSurfaceStyle.pane.color)
    }
}
