import Cocoa
import SwiftUI

/// Extensions on NSView and SwiftUI types used throughout the app.
extension NSView {
    /// Embed a SwiftUI view inside this NSView using NSHostingView.
    func addSwiftUISubview<Content: View>(_ view: Content) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: view)
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
