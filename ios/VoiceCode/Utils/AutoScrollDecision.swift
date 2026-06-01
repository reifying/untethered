// AutoScrollDecision.swift
// Pure auto-scroll decisions, extracted from ConversationView so the policy
// (whether/when to scroll) is unit-testable without a live UICollectionView.
//
// Scope note: this helper covers only the *policy*. The crash-preventing part —
// that the List actually *targets the always-present bottom anchor* — is not
// expressible here (it lives in the SwiftUI view body) and is covered by code
// review and the manual repro, not by a unit test.
//
// No SwiftUI / UIKit / Foundation here: pure Int/Bool logic.
//
// See docs/design/conversation-autoscroll-crash-fix.md (API Design).

enum AutoScrollDecision {

    /// Schedule-time gate: a count change should schedule an auto-scroll only
    /// when the list grew, auto-scroll is enabled, and the sheet is not open.
    static func shouldAutoScroll(oldCount: Int,
                                 newCount: Int,
                                 autoScrollEnabled: Bool,
                                 isSheetOpen: Bool) -> Bool {
        guard newCount > oldCount else { return false }  // only on growth
        return shouldStillScroll(autoScrollEnabled: autoScrollEnabled, isSheetOpen: isSheetOpen)
    }

    /// Fire-time re-gate (no counts): growth was already established at schedule
    /// time; by the time the debounced closure runs the user may have toggled
    /// auto-scroll off or opened the "View Full" sheet, so re-check just those.
    static func shouldStillScroll(autoScrollEnabled: Bool, isSheetOpen: Bool) -> Bool {
        autoScrollEnabled && !isSheetOpen
    }

    /// A debounced scroll is stale if a newer scroll was scheduled after it.
    /// `scheduledGeneration` is captured at schedule time; `currentGeneration`
    /// is read at fire time. (Documents the coalescing intent; the comparison
    /// itself is trivial.)
    static func isCurrent(scheduledGeneration: Int, currentGeneration: Int) -> Bool {
        scheduledGeneration == currentGeneration
    }
}
