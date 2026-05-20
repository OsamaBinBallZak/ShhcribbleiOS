import SwiftUI

/// Captures the SwiftUI environment's `OpenURLAction` and hands it to a
/// callback so it can be invoked from non-View code (e.g. a UIKit
/// `@objc` action on `KeyboardViewController`).
///
/// Why this exists: `NSExtensionContext.open(_:completionHandler:)` is
/// documented Today-widget-only and iOS statically refuses it for
/// keyboard extensions. The supported path on iOS 18+ is SwiftUI's
/// `openURL` environment action, which traverses the responder chain
/// through SwiftUI's infrastructure (a path iOS still permits). To
/// invoke that action from a UIKit `@IBAction`-style handler, we need
/// to capture the environment value while inside a View body and
/// thread it back up.
///
/// Usage:
///
///     setupKeyboardView { _ in
///         OpenURLCapture(onCapture: { [weak self] action in
///             self?.capturedOpenURL = action
///         }) {
///             KeyboardRootView(...)
///         }
///     }
///
/// References: getdictus/dictus-ios, Joevonlong/Vowrite, and
/// KeyboardKit 8.8.6+ all use this same pattern.
struct OpenURLCapture<Content: View>: View {
    let onCapture: (OpenURLAction) -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.openURL) private var openURL

    var body: some View {
        content()
            .onAppear { onCapture(openURL) }
    }
}
