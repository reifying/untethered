// DesktopDensity.swift
// Platform-specific constants and view modifiers for macOS information density

#if os(macOS)
import SwiftUI

struct DesktopDensity {
    // Spacing
    static let listRowVerticalPadding: CGFloat = 4
    static let listRowHorizontalPadding: CGFloat = 8
    static let sectionSpacing: CGFloat = 8

    // Typography
    static let bodyFont: Font = .system(size: 13)
    static let captionFont: Font = .system(size: 11)
    static let messageFont: Font = .system(size: 13)

    // Truncation
    static let messagePreviewLines: Int = 3
    static let messageTruncationThreshold: Int = 2000  // vs 500 on iOS

    // Sizing
    static let minRowHeight: CGFloat = 28
    static let iconSize: CGFloat = 14
}

extension View {
    func desktopDensity() -> some View {
        self.font(DesktopDensity.bodyFont)
    }

    func desktopListRow() -> some View {
        self
            .padding(.vertical, DesktopDensity.listRowVerticalPadding)
            .padding(.horizontal, DesktopDensity.listRowHorizontalPadding)
    }
}
#endif
