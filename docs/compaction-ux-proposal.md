# Session Compaction UX Proposal

## Overview

Proposal for integrating session compaction into the voice-code iOS app to help users manage conversation history and optimize performance.

## User Problems

1. **Session files grow large over time** - Long conversations accumulate hundreds of messages
2. **Performance degradation** - Large sessions slow down loading and synchronization
3. **Context window limits** - Claude has token limits that can be hit during long sessions
4. **Storage concerns** - Users may want to reduce on-disk footprint

## Proposed Solutions

### Option A: Proactive Manual Control (Recommended)

**Location**: SessionDetailView header/toolbar

**UI Elements**:
```
┌─────────────────────────────────────┐
│ ← Session Name              [⚡︎] [⋮] │  ← Compact button + menu
├─────────────────────────────────────┤
│ Session Info                        │
│ • 147 messages                      │
│ • 42.3K tokens                      │
│ • Last used: 2 hours ago            │
│                                     │
│ [💬 Continue Session]               │
│                                     │
│ Conversation History                │
│ ─────────────────────────────       │
```

**Compact Button** (⚡︎):
- Icon: Lightning bolt or compress icon
- Placement: Top-right toolbar
- Behavior: Tap → Show confirmation dialog
- Badge: Show suggestion indicator when sessions exceed threshold

**Confirmation Dialog**:
```
┌─────────────────────────────────────┐
│        Compact Session?             │
├─────────────────────────────────────┤
│                                     │
│ This will summarize your            │
│ conversation history to reduce      │
│ file size and improve performance.  │
│                                     │
│ Current: 147 messages (42.3K tokens)│
│ After:   ~20 messages (est.)        │
│                                     │
│ ⚠️ This cannot be undone            │
│                                     │
│          [Cancel]  [Compact]        │
└─────────────────────────────────────┘
```

**Progress State**:
```
┌─────────────────────────────────────┐
│ Compacting session...               │
│ [────────────────────] 100%         │
│                                     │
│ This may take 10-30 seconds         │
└─────────────────────────────────────┘
```

**Success Toast**:
```
✓ Session compacted
  Removed 127 messages, saved 40.1K tokens
```

**Pros**:
- Users have explicit control
- Clear before/after statistics
- Easy to discover in session detail view
- Can show recommendations without forcing action

**Cons**:
- Requires user awareness and action
- Users may ignore until performance suffers

---

### Option B: Smart Suggestions (Hybrid Approach)

**Auto-detect when compaction would be beneficial**:
- Sessions > 100 messages
- Sessions > 50K tokens
- Sessions with multiple compact_boundary markers (already compacted before)
- Sessions not used in > 7 days

**UI**: Banner in SessionDetailView
```
┌─────────────────────────────────────┐
│ ← Session Name                      │
├─────────────────────────────────────┤
│ ┌─────────────────────────────────┐ │
│ │ 💡 Suggestion                   │ │
│ │ This session has 147 messages.  │ │
│ │ Compact to improve performance? │ │
│ │                                 │ │
│ │ [Maybe Later]  [Compact Now]    │ │
│ └─────────────────────────────────┘ │
│                                     │
│ Session Info                        │
│ ...                                 │
```

**Pros**:
- Guides users toward best practices
- Non-intrusive suggestions
- Can be dismissed
- Educates users about compaction benefits

**Cons**:
- More complex logic
- May feel naggy if suggestions are too frequent
- Users may habitually dismiss

---

### Option C: Settings-Based Automation

**Location**: App Settings → Session Management

**Options**:
```
Session Compaction
├─ Auto-compact sessions
│  ☑ Automatically compact after 100 messages
│  ☑ Automatically compact after 7 days inactive
│
├─ Compaction Threshold
│  [Slider: 50 - 200 messages]
│
└─ Show Compaction Notifications
   ☑ Notify when sessions are compacted
```

**Pros**:
- Set-and-forget convenience
- Consistent performance optimization
- Users can customize thresholds

**Cons**:
- Less visibility into what's happening
- Users may forget it's enabled
- Could surprise users if they don't understand compaction
- Risk of compacting sessions users wanted to preserve

---

### Option D: Context Menu Integration

**Location**: SwiftUI context menu on session list items

```
Long-press session → Context Menu:
┌─────────────────────────┐
│ 📝 Rename               │
│ 📋 Duplicate            │
│ ⚡︎ Compact Session      │
│ 🗑  Delete              │
└─────────────────────────┘
```

**Pros**:
- Accessible without entering session detail
- Familiar iOS pattern
- Doesn't clutter main UI

**Cons**:
- Less discoverable
- Users may not know about context menus
- Harder to show statistics/preview

---

## ✓ APPROVED APPROACH: **Option A (Manual Control)**

Simple, user-controlled compaction with no automation:

1. **Primary**: Compact button (⚡︎) always visible in SessionDetailView toolbar
2. **No minimums**: Works on any session
3. **No undo**: Permanent operation with clear warning
4. **No auto-compact**: User must manually trigger

### Implementation Phases

**Phase 1: Core Functionality (v1)** ← CURRENT FOCUS
- voice-code-216: Backend WebSocket handler
- voice-code-217: Backend compact-session function
- voice-code-218: Message counting utility
- voice-code-219: iOS VoiceCodeClient method
- voice-code-220: iOS UI - Compact button in toolbar (⚡︎)
- voice-code-221: Documentation updates
- voice-code-222: Edge case testing

**Phase 2: Smart Suggestions (Future)**
- Smart suggestion banner when sessions are large
- Educational tooltips
- Usage analytics

**Phase 3: Advanced Features (Future)**
- Compact all sessions bulk operation
- Compaction history view

---

## User Flow: First-Time Compaction

1. **Discovery**: User opens session with 150+ messages
2. **Suggestion**: Banner appears: "💡 This session has grown large. Compact to improve performance?"
3. **Education**: Tap "Learn More" → Short explanation of compaction benefits
4. **Action**: User taps "Compact Now"
5. **Confirmation**: Dialog shows before/after estimates
6. **Progress**: Progress indicator during compaction (10-30 seconds)
7. **Success**: Toast shows statistics: "✓ Removed 127 messages, saved 40.1K tokens"
8. **Result**: Session detail view updates with new message count

---

## Visual Design Guidelines

### Icons
- **Compact Button**: ⚡︎ (lightning) or ⤓ (compress arrows)
- **Suggestion Badge**: Blue dot or number indicator
- **Success**: ✓ checkmark
- **Warning**: ⚠️ triangle

### Colors
- **Compact Button**: Accent blue (system)
- **Suggestion Banner**: Light blue background (#E3F2FD)
- **Warning Text**: Amber (#FFA000)
- **Success Toast**: Green (#4CAF50)

### Animations
- **Button Press**: Scale down 0.95x
- **Progress**: Indeterminate spinner or determinate bar
- **Toast**: Slide up from bottom, auto-dismiss after 3 seconds
- **Banner Dismiss**: Slide out to right

---

## Copy Guidelines

### Button Labels
- Primary: "Compact" (not "Compress" or "Reduce")
- Secondary: "Compact Session", "Compact Now"
- Menu: "⚡︎ Compact Session"

### Confirmation Dialog
- Title: "Compact Session?" (concise)
- Body: Explain action + consequences + statistics
- Warning: "⚠️ This cannot be undone" (emphasize permanence)
- Actions: "Cancel" (default) + "Compact" (destructive style)

### Success Messages
- Short: "Session compacted"
- Detailed: "Removed X messages, saved Y tokens"
- Avoid: Technical jargon like "JSONL", "compact_boundary", etc.

### Error Messages
- Generic: "Couldn't compact session. Please try again."
- Specific: "Session not found" / "Compaction failed: [reason]"
- Actionable: "Check your network connection and try again"

---

## Accessibility

- **VoiceOver**: All buttons labeled clearly
  - Compact button: "Compact session, removes old messages"
  - Suggestion banner: "Suggestion: Compact this session to improve performance"
- **Dynamic Type**: Support all text sizes
- **Reduce Motion**: Skip animations, show instant state changes
- **Color Contrast**: All text meets WCAG AA standards

---

## Analytics & Monitoring

Track these events to measure adoption and improve UX:

```swift
// Events
analytics.track("compaction_suggestion_shown", properties: [
    "message_count": 147,
    "token_count": 42300,
    "session_age_days": 14
])

analytics.track("compaction_initiated", properties: [
    "trigger": "button" | "suggestion" | "context_menu"
])

analytics.track("compaction_completed", properties: [
    "old_message_count": 147,
    "new_message_count": 20,
    "messages_removed": 127,
    "pre_tokens": 42300,
    "duration_seconds": 15.3
])

analytics.track("compaction_failed", properties: [
    "error": "session_not_found" | "network_error" | "timeout"
])
```

---

## Decisions Made

1. **Minimum threshold**: ✓ **NO MINIMUM** - Allow compaction on any session
   - User decides when to compact, no artificial restrictions

2. **Active session compaction**: ✓ **ALLOWED** - User can compact currently active session
   - Warning in confirmation dialog about resetting context

3. **Undo support**: ✗ **NOT IMPLEMENTING** - Compaction is permanent
   - Clear "Cannot be undone" warning in confirmation dialog
   - No backup, no rollback functionality

4. **Bulk operations**: ⏸ **PHASE 3** - "Compact All Sessions" deferred to future
   - Focus on single-session compaction first

5. **Auto-compact**: ✗ **NOT IMPLEMENTING** - Always require user action
   - Phase 2 may add smart suggestions, but never auto-compact without consent

6. **Education**: ⏸ **PHASE 2** - Smart suggestions will educate users
   - Show before/after stats in confirmation dialog
   - Success toast reinforces benefits with actual numbers

---

## Success Metrics

After launch, measure:

1. **Adoption Rate**: % of eligible sessions that get compacted
   - Target: 30% within first month

2. **User Satisfaction**: Ratings/feedback mentioning performance
   - Monitor for positive mentions of speed improvements

3. **Error Rate**: % of compaction attempts that fail
   - Target: <5% failure rate

4. **Performance Impact**: Session load time before/after compaction
   - Expected: 20-50% faster load times for large sessions

5. **Storage Savings**: Average JSONL file size reduction
   - Expected: 60-80% size reduction for heavily-used sessions

---

## Next Steps

1. ✓ Create backend tasks (voice-code-216, 217, 218)
2. ✓ Create iOS tasks (voice-code-219, 220)
3. ✓ Create documentation task (voice-code-221)
4. Review this UX proposal with team/stakeholders
5. Create mockups/designs for Option A + B
6. Implement Phase 1 (core functionality)
7. Test with beta users
8. Iterate based on feedback
9. Launch Phase 2 (smart suggestions)

---

## References

- Claude CLI Testing: `/docs/claude-compact-testing.md`
- WebSocket Protocol: `STANDARDS.md`
- Parent Task: voice-code-168
