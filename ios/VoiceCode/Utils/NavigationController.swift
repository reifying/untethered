// NavigationController.swift
// Reusable navigation container component for cross-platform (macOS/iOS) navigation

import SwiftUI

/// A reusable navigation container that provides consistent navigation behavior
/// across macOS and iOS platforms.
///
/// On macOS: Uses NavigationStack with configurable minimum frame size
/// On iOS: Uses NavigationView for standard iOS navigation
///
/// Usage:
/// ```swift
/// NavigationController(minWidth: 450, minHeight: 350) {
///     YourContentView()
/// }
/// ```
struct NavigationController<Content: View>: View {
    let content: Content
    let minWidth: CGFloat
    let minHeight: CGFloat

    init(minWidth: CGFloat = 450, minHeight: CGFloat = 350, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.minWidth = minWidth
        self.minHeight = minHeight
    }

    var body: some View {
        #if os(macOS)
        NavigationStack {
            content
        }
        .frame(minWidth: minWidth, minHeight: minHeight)
        #else
        NavigationView {
            content
        }
        #endif
    }
}

// MARK: - Preview

#if DEBUG
struct NavigationController_Previews: PreviewProvider {
    static var previews: some View {
        NavigationController(minWidth: 400, minHeight: 300) {
            Text("Preview Content")
                .navigationTitle("Preview")
        }
    }
}
#endif
