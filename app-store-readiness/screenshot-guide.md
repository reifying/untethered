# Screenshot Capture Guide - Untethered

**App:** Untethered (VoiceCode)
**Bundle ID:** dev.910labs.voice-code
**Purpose:** App Store submission screenshots
**Last Updated:** November 8, 2025

---

## Required Specifications

### iPhone Screenshots (Required)

**Target Device:** iPhone 15 Pro Max (6.7" display)
**Resolution:** 1290 × 2796 pixels (portrait)
**Format:** PNG (preferred) or JPEG
**Color Space:** sRGB or Display P3
**Quantity:** 4-6 screenshots
**Order:** Matters - first screenshot is most important

### iPad Screenshots (Recommended)

**Target Device:** iPad Pro 12.9"
**Resolution:** 2048 × 2732 pixels (portrait)
**Format:** PNG (preferred) or JPEG
**Quantity:** 4-6 screenshots

---

## Setup Instructions

### 1. Prepare Simulator

```bash
# Create iPhone 15 Pro Max simulator if needed
xcrun simctl create "iPhone 15 Pro Max" "iPhone 15 Pro Max"

# Boot simulator
xcrun simctl boot "iPhone 15 Pro Max"

# Open Simulator app
open -a Simulator

# Set appearance to Light mode (recommended for screenshots)
# Simulator → Device → Appearance → Light

# Set to 100% scale for best quality
# Window → Physical Size (or Cmd+1)
```

### 2. Prepare App Data

Before capturing screenshots, populate the app with realistic data:

**Create Test Projects:**
- Project 1: "voice-code" (this app's codebase)
- Project 2: "mobile-app" (example iOS project)
- Project 3: "backend-api" (example backend)

**Create Test Sessions:**
- At least 3-5 sessions per project
- Mix of recent and older sessions
- Realistic session names (not "test" or "foo")
- Populate with actual conversation history

**Server Setup:**
- Ensure backend is running and connected
- Connection status shows "Connected" (green)
- No error messages visible

**Settings:**
- Configure a premium voice (e.g., "Samantha (Premium)" or "Alex")
- Set Recent Sessions Limit to 10
- Enable "Read Aloud" notifications

### 3. Build and Run

```bash
# From project root
cd ios

# Build and run on simulator
xcodebuild build -scheme VoiceCode -destination 'platform=iOS Simulator,name=iPhone 15 Pro Max'

# Or use Xcode:
# Open VoiceCode.xcodeproj
# Select iPhone 15 Pro Max simulator
# Cmd+R to run
```

---

## Screenshot Capture Checklist

### Screenshot 1: Projects/Sessions List ⭐ (Most Important)

**Purpose:** First impression - show main interface and organization

**Setup:**
1. Navigate to main Projects screen
2. Ensure Recent Sessions section has 3-5 sessions
3. Ensure Projects section shows at least 2 directories
4. Connection status shows "Connected" (green)
5. No error messages or empty states
6. Navigation title shows "Projects"

**Composition:**
- Top: Navigation bar with "Projects" title and icons
- Upper section: "Recent" with session items showing:
  - Session names
  - Directory paths
  - Timestamps ("2 hours ago", "Yesterday")
  - Unread badges (optional - adds interest)
- Lower section: "Projects" with directory items showing:
  - Directory names
  - Session counts ("3 sessions")
  - Folder icons
- Bottom: No toolbar or tabs (clean)

**Capture:**
```bash
# Using Simulator menu
# Device → Screenshot (or Cmd+S)
# Saves to Desktop

# Or using xcrun
xcrun simctl io booted screenshot screenshot-1-projects.png
```

**Post-Processing:**
- Verify resolution: 1290 × 2796 pixels
- Check colors look good
- Ensure text is readable
- Consider adding device frame (optional)

---

### Screenshot 2: Active Conversation ⭐

**Purpose:** Demonstrate voice interaction and AI responses

**Setup:**
1. Open a session with existing conversation history
2. Scroll to show mix of user and assistant messages
3. Ensure voice button is visible (not covered by keyboard)
4. Connection status shows "Connected"
5. Auto-scroll toggle visible
6. Session name shows in navigation bar

**Composition:**
- Top: Navigation bar with session name (e.g., "Refactor authentication")
- Connection indicator (green dot + "Connected")
- Conversation messages showing:
  - User messages (blue bubbles, left-aligned)
  - Assistant messages (green bubbles, left-aligned)
  - Realistic coding questions/responses
  - Proper spacing and readability
- Bottom: Large circular voice button (prominent)
- Auto-scroll toggle visible
- Text input toggle (small button)

**Sample Conversation Content:**
```
User: "Explain how session sync works in this codebase"