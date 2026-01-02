# macOS Desktop App MVP

## Overview

### Problem Statement

The voice-code iOS app provides a mobile interface to Claude Code sessions, but users working at their desk need a native desktop experience. Currently, there's no way to use voice-code features without picking up a phone.

### Goals

1. Create a macOS native app with full feature parity to iOS
2. Maximize code sharing between iOS and macOS (target: 95%+)
3. Use XcodeGen's multi-platform support via `project.yml`
4. No desktop-specific UX enhancements in MVP

### Non-goals

- Desktop-specific features (menu bar, keyboard shortcuts, window management)
- Multi-window support
- Touch Bar integration
- macOS-specific UI patterns (sidebar navigation vs mobile stack)
- Code refactoring into Swift Package (deferred to post-MVP)
- macOS Share Extension (iOS Share Extension not ported in MVP)

## Background & Context

### Current State

The iOS app is a fully functional SwiftUI application with:
- 43 Swift source files across Models, Views, Managers, Utils
- CoreData persistence with 4 entity types
- WebSocket communication with Clojure backend
- Voice input (Speech framework) and output (AVSpeechSynthesizer)
- Command execution, recipes, and resource management

### Why Now

Desktop users need voice-code access without reaching for their phone. The iOS codebase is mature enough to share.

### Related Work

- @STANDARDS.md - WebSocket protocol (shared with macOS)
- @ios/project.yml - XcodeGen project definition
- @ios/XCODEGEN.md - XcodeGen usage documentation

## Detailed Design

### Sharing Strategy

**Approach: Single Xcode project with iOS and macOS targets sharing source files**

XcodeGen supports `supportedDestinations` to build the same source for multiple platforms. Combined with `#if os(macOS)` conditionals for platform-specific code, this maximizes sharing without requiring a Swift Package refactor.

### Files That Cannot Share (iOS-only APIs)

| File | iOS-Only API | macOS Solution |
|------|--------------|----------------|
| `DeviceAudioSessionManager.swift` | `AVAudioSession` (silent switch) | Exclude from macOS target |
| `VoiceInputManager.swift` | `AVAudioSession.sharedInstance()` | Conditional: use `AVAudioEngine` directly |
| `VoiceCodeClient.swift` | `UIApplication` notifications | Conditional: use `NSApplication` |
| `VoiceOutputManager.swift` | `AVAudioSession` for background | Conditional: skip session management, guard `audioSessionManager` property |
| `VoiceCodeApp.swift` | `UIApplication` lifecycle | Conditional: use `NSApplication` |

**Views requiring clipboard/haptic conditionals (7 files):**

| View File | iOS API Used | macOS Solution |
|-----------|--------------|----------------|
| `DirectoryListView.swift` | `UIPasteboard`, `UINotificationFeedbackGenerator` | `NSPasteboard`, no-op haptics |
| `SessionsForDirectoryView.swift` | `UIPasteboard`, `UINotificationFeedbackGenerator` | `NSPasteboard`, no-op haptics |
| `SessionLookupView.swift` | `UIPasteboard`, `UINotificationFeedbackGenerator` | `NSPasteboard`, no-op haptics |
| `SessionInfoView.swift` | `UIPasteboard`, `UINotificationFeedbackGenerator` | `NSPasteboard`, no-op haptics |
| `ConversationView.swift` | `UIPasteboard`, `UINotificationFeedbackGenerator` | `NSPasteboard`, no-op haptics |
| `DebugLogsView.swift` | `UIPasteboard`, `UINotificationFeedbackGenerator` | `NSPasteboard`, no-op haptics |
| `CommandOutputDetailView.swift` | `UIPasteboard`, `UINotificationFeedbackGenerator` | `NSPasteboard`, no-op haptics |

**Note:** `NotificationManager.swift` uses `UserNotifications` framework which is available on both platforms. The API is identical, so no conditionals needed. However, notification behavior may differ (e.g., notification center presentation) and should be tested on macOS.

### Files That Share Directly (95%+ of codebase)

- **All CoreData models**: `CDBackendSession`, `CDMessage`, `CDUserSession`, extensions
- **All data models**: `Message`, `RecentSession`, `Command`, `Recipe`, `Resource`
- **All managers** (with minor conditionals): `VoiceCodeClient`, `SessionSyncManager`, `AppSettings`, `PersistenceController`, `DraftManager`, `ResourcesManager`, `ActiveSessionManager`, `NotificationManager`
- **All views**: SwiftUI is cross-platform; navigation patterns work on both
- **All utilities**: `RenderTracker`, date formatting, etc.

### Code Changes Required

#### 1. VoiceCodeClient.swift - Lifecycle Notifications

```swift
// Current (iOS-only)
import UIKit

private func setupLifecycleObservers() {
    NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        ...
    )
}

// Updated (cross-platform)
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private func setupLifecycleObservers() {
    #if os(iOS)
    NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        self?.handleAppBecameActive()
    }
    NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        self?.handleAppEnteredBackground()
    }
    #elseif os(macOS)
    NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        self?.handleAppBecameActive()
    }
    NotificationCenter.default.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        self?.handleAppEnteredBackground()
    }
    #endif
}

private func handleAppBecameActive() {
    if !isConnected {
        print("📱 [VoiceCodeClient] App became active, attempting reconnection...")
        reconnectionAttempts = 0
        connect(sessionId: sessionId)
    }
}

private func handleAppEnteredBackground() {
    print("📱 [VoiceCodeClient] App entering background")
}
```

#### 2. VoiceInputManager.swift - Audio Session

```swift
// Current (iOS-only)
let audioSession = AVAudioSession.sharedInstance()
try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

// Updated (cross-platform)
func startRecording() {
    guard authorizationStatus == .authorized else { return }

    if recognitionTask != nil {
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    #if os(iOS)
    // iOS requires explicit audio session configuration
    let audioSession = AVAudioSession.sharedInstance()
    do {
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
        print("Failed to setup audio session: \(error)")
        return
    }
    #endif
    // macOS: AVAudioEngine handles audio routing automatically

    // Rest of implementation unchanged...
}

func stopRecording() {
    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio()

    DispatchQueue.main.async {
        self.isRecording = false
    }

    #if os(iOS)
    let audioSession = AVAudioSession.sharedInstance()
    try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    #endif
}
```

#### 3. VoiceOutputManager.swift - Background Playback

```swift
class VoiceOutputManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    // ... other properties ...

    // iOS-only: Audio session manager for silent switch handling
    #if os(iOS)
    private let audioSessionManager = DeviceAudioSessionManager()
    #endif

    // iOS-only: Background playback support
    #if os(iOS)
    private var silencePlayer: AVAudioPlayer?
    private var keepAliveTimer: Timer?
    #endif

    // ... init and other methods ...

    func speakWithVoice(_ text: String, rate: Float = 0.5, voiceIdentifier: String? = nil, respectSilentMode: Bool = false) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        #if os(iOS)
        // iOS requires explicit audio session configuration
        do {
            let shouldRespectSilentMode = respectSilentMode && (appSettings?.respectSilentMode ?? true)
            if shouldRespectSilentMode {
                try audioSessionManager.configureAudioSessionForSilentMode()
            } else {
                try audioSessionManager.configureAudioSessionForForcedPlayback()
            }
        } catch {
            print("Failed to setup audio session: \(error)")
            return
        }
        #endif
        // macOS: No audio session management needed

        // Create utterance (unchanged)...
    }

    // Background keep-alive only needed on iOS
    private func startKeepAliveTimer() {
        #if os(iOS)
        guard appSettings?.continuePlaybackWhenLocked ?? true else { return }
        stopKeepAliveTimer()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            self?.playSilence()
        }
        #endif
    }

    private func stopKeepAliveTimer() {
        #if os(iOS)
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        #endif
    }

    #if os(iOS)
    private func setupSilencePlayer() {
        // iOS-only: Create silent audio buffer for background keep-alive
        // ... existing implementation ...
    }

    private func playSilence() {
        silencePlayer?.play()
    }
    #endif
}
```

#### 4. DeviceAudioSessionManager.swift - Exclude from macOS

This file is iOS-only (silent switch handling). Exclude from macOS target in `project.yml`.

#### 5. VoiceCodeApp.swift - Platform Lifecycle

```swift
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct RootView: View {
    // ... existing properties ...

    var body: some View {
        NavigationStack(path: $navigationPath) {
            // ... existing implementation ...
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            resourcesManager.updatePendingCount()
            if client.isConnected {
                resourcesManager.processPendingUploads()
            }
        }
        #elseif os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            resourcesManager.updatePendingCount()
            if client.isConnected {
                resourcesManager.processPendingUploads()
            }
        }
        #endif
    }
}
```

#### 6. ClipboardUtility.swift (NEW) - Shared Clipboard Helper

Create a new utility file to centralize clipboard operations and avoid duplicating platform conditionals across 7 view files:

```swift
// ClipboardUtility.swift
// Cross-platform clipboard and haptic feedback utilities

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum ClipboardUtility {
    /// Copy text to system clipboard with optional haptic feedback (iOS only)
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// Trigger success haptic feedback (iOS only, no-op on macOS)
    static func triggerSuccessHaptic() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif
        // macOS: No haptic feedback available
    }
}
```

#### 7. View Updates - Use ClipboardUtility

Update all 7 view files to use the shared utility:

```swift
// Example: DirectoryListView.swift (and 6 other views)
private func copyToClipboard(_ text: String, message: String) {
    ClipboardUtility.copy(text)
    ClipboardUtility.triggerSuccessHaptic()

    copyConfirmationMessage = message
    withAnimation {
        showingCopyConfirmation = true
    }
    // ... rest unchanged
}
```

This approach:
- Centralizes platform-specific code in one file
- Reduces conditional compilation scattered across views
- Makes future clipboard changes easier to maintain

### Project Configuration

#### Updated project.yml

```yaml
name: VoiceCode

options:
  bundleIdPrefix: dev.910labs
  deploymentTarget:
    iOS: "18.5"
    macOS: "15.0"
  developmentLanguage: en
  createIntermediateGroups: true
  generateEmptyDirectories: false

settings:
  base:
    DEVELOPMENT_TEAM: REDACTED_TEAM_ID_2
    CODE_SIGN_STYLE: Automatic
    MARKETING_VERSION: "1.0"
    CURRENT_PROJECT_VERSION: 90

targets:
  VoiceCode:
    type: application
    platform: iOS
    deploymentTarget: "18.5"
    supportedDestinations:
      - iOS
    sources:
      - path: VoiceCode
        excludes:
          - "*.md"
    resources:
      - VoiceCode/Assets.xcassets
      - VoiceCode/VoiceCode.xcdatamodeld
      - VoiceCode/PrivacyInfo.xcprivacy
    info:
      path: VoiceCode/Info.plist
      properties:
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        CFBundleDisplayName: Untethered
        CFBundleIconName: AppIcon
        NSMicrophoneUsageDescription: Untethered needs microphone access for voice input to control Claude.
        NSSpeechRecognitionUsageDescription: Untethered needs speech recognition to transcribe your voice commands.
        NSLocalNetworkUsageDescription: Untethered needs to connect to your backend server on your local network.
        UIBackgroundModes:
          - audio
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: true
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationPortraitUpsideDown
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UILaunchScreen:
          UIColorName: ""
          UIImageName: ""
        ITSAppUsesNonExemptEncryption: false
    entitlements:
      path: VoiceCode/VoiceCode.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.910labs.untethered.resources
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.910labs.voice-code
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        INFOPLIST_FILE: VoiceCode/Info.plist
        LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/Frameworks"
    dependencies:
      - target: VoiceCodeShareExtension
        embed: true

  VoiceCodeMac:
    type: application
    platform: macOS
    deploymentTarget: "15.0"
    supportedDestinations:
      - macOS
    sources:
      - path: VoiceCode
        excludes:
          - "*.md"
          - "Managers/DeviceAudioSessionManager.swift"  # iOS-only
    resources:
      - VoiceCode/Assets.xcassets
      - VoiceCode/VoiceCode.xcdatamodeld
    info:
      path: VoiceCodeMac/Info.plist
      properties:
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        CFBundleDisplayName: Untethered
        CFBundleIconName: AppIcon
        NSMicrophoneUsageDescription: Untethered needs microphone access for voice input to control Claude.
        NSSpeechRecognitionUsageDescription: Untethered needs speech recognition to transcribe your voice commands.
        NSLocalNetworkUsageDescription: Untethered needs to connect to your backend server on your local network.
    entitlements:
      path: VoiceCodeMac/VoiceCodeMac.entitlements
      properties:
        com.apple.security.app-sandbox: true
        com.apple.security.network.client: true
        com.apple.security.device.audio-input: true
        com.apple.security.files.user-selected.read-write: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.910labs.voice-code-mac
        INFOPLIST_FILE: VoiceCodeMac/Info.plist
        LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/../Frameworks"
        COMBINE_HIDPI_IMAGES: YES

  VoiceCodeShareExtension:
    # ... unchanged ...

  VoiceCodeTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "18.5"
    sources:
      - VoiceCodeTests
    resources:
      - VoiceCodeTests/Fixtures
    dependencies:
      - target: VoiceCode
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.910labs.voice-codeTests
        GENERATE_INFOPLIST_FILE: YES

  VoiceCodeMacTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: "15.0"
    sources:
      - path: VoiceCodeTests
        excludes:
          # iOS-only tests (use AVAudioSession or UIPasteboard)
          - "DeviceAudioSessionManagerTests.swift"
          - "VoiceOutputManagerTests.swift"
          - "CopyFeaturesTests.swift"
          - "SessionInfoViewTests.swift"
    resources:
      - VoiceCodeTests/Fixtures
    dependencies:
      - target: VoiceCodeMac
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.910labs.voice-code-macTests
        GENERATE_INFOPLIST_FILE: YES

schemes:
  VoiceCode:
    build:
      targets:
        VoiceCode: all
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - name: VoiceCodeTests

  VoiceCodeMac:
    build:
      targets:
        VoiceCodeMac: all
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - name: VoiceCodeMacTests
```

### Directory Structure Changes

```
ios/
├── VoiceCode/                    # Shared source (iOS + macOS)
│   ├── Models/                   # Fully shared
│   ├── Views/                    # Shared with conditionals
│   ├── Managers/                 # Shared with conditionals
│   │   └── DeviceAudioSessionManager.swift  # iOS-only (excluded from macOS)
│   ├── Utils/                    # Fully shared
│   ├── VoiceCodeApp.swift        # Shared with conditionals
│   └── Assets.xcassets           # Shared (add macOS icon)
├── VoiceCodeMac/                 # macOS-specific (NEW)
│   ├── Info.plist                # macOS Info.plist
│   └── VoiceCodeMac.entitlements # macOS entitlements
├── VoiceCodeShareExtension/      # iOS-only
├── VoiceCodeTests/               # Shared tests
└── project.yml                   # Updated with macOS target
```

### New Files Required

#### VoiceCodeMac/Info.plist

**Note:** For pure SwiftUI apps using `@main`, `NSMainStoryboardFile` should be empty (no storyboard) and `NSPrincipalClass` is set to `NSApplication`. The `@main` attribute on the App struct handles app lifecycle initialization.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>NSMainStoryboardFile</key>
    <string></string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Untethered needs microphone access for voice input to control Claude.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Untethered needs speech recognition to transcribe your voice commands.</string>
</dict>
</plist>
```

#### VoiceCodeMac/VoiceCodeMac.entitlements

**Note:** App Groups entitlement is intentionally omitted. On iOS, App Groups enable file sharing between the main app and Share Extension via a shared container. Since macOS Share Extension is out of scope for MVP, the app group is not needed. `ResourcesManager.swift` will fail gracefully when `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil on macOS—the resource upload feature will be non-functional until a macOS Share Extension is added post-MVP.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

### Assets.xcassets Updates

Add macOS app icon set:

```
Assets.xcassets/
├── AppIcon.appiconset/           # Existing iOS icons
└── AppIcon-macOS.appiconset/     # NEW: macOS icons (16, 32, 64, 128, 256, 512, 1024)
```

Or use a single `AppIcon.appiconset` with both iOS and macOS sizes.

## Verification Strategy

### Testing Approach

#### Unit Tests

Existing `VoiceCodeTests` run against both targets:
- iOS: `VoiceCodeTests` target (all 52 test files)
- macOS: `VoiceCodeMacTests` target (excludes 4 iOS-only test files)

**iOS-only test files (excluded from macOS target):**
- `DeviceAudioSessionManagerTests.swift` — tests `AVAudioSession` (iOS-only API)
- `VoiceOutputManagerTests.swift` — tests audio session configuration
- `CopyFeaturesTests.swift` — tests `UIPasteboard` clipboard operations
- `SessionInfoViewTests.swift` — tests `UIPasteboard` clipboard operations

Tests use the same source files, verifying shared code works on both platforms. The excluded tests validate iOS-specific behavior that doesn't apply to macOS.

#### Integration Tests

1. WebSocket connection to backend
2. CoreData persistence (same model, both platforms)
3. Session sync from backend
4. Command execution flow

#### Manual Testing

| Feature | iOS | macOS |
|---------|-----|-------|
| Server configuration | Settings sheet | Settings sheet |
| Session list display | DirectoryListView | DirectoryListView |
| Conversation view | ConversationView | ConversationView |
| Voice input | Microphone button | Microphone button |
| Voice output | Speak button | Speak button |
| Command execution | CommandMenuView | CommandMenuView |
| Recipes | RecipeMenuView | RecipeMenuView |
| Resources | ResourcesView | ResourcesView |

### Acceptance Criteria

1. macOS app builds successfully with `xcodegen generate && xcodebuild -scheme VoiceCodeMac`
2. App launches and connects to backend server
3. Session list displays correctly
4. Conversations display and allow text input
5. Voice input captures and transcribes speech
6. Voice output speaks assistant responses
7. Command menu shows Makefile targets and executes commands
8. Recipes display and execute
9. Resources view shows uploaded files
10. Settings persist across launches
11. All existing iOS unit tests pass
12. All unit tests pass on macOS target

## Alternatives Considered

### 1. Swift Package for Shared Code

**Approach:** Extract shared code into a local Swift Package, import into both iOS and macOS apps.

**Pros:**
- Clean separation of shared vs platform-specific
- Easier to test shared code in isolation
- Better compile times (package caching)

**Cons:**
- Significant refactoring required
- More complex project structure
- CoreData model sharing requires careful setup

**Decision:** Deferred to post-MVP. Multi-platform target achieves sharing with minimal changes.

### 2. Catalyst (Mac Catalyst)

**Approach:** Enable "Mac (Designed for iPad)" or Mac Catalyst for the iOS app.

**Pros:**
- Zero code changes
- Instant macOS support

**Cons:**
- Catalyst apps feel like iOS apps on Mac
- Limited access to macOS-specific features
- Poor integration with macOS window management

**Decision:** Rejected. Native macOS target provides better user experience.

### 3. Electron/Tauri Cross-Platform

**Approach:** Rewrite frontend in web technologies.

**Pros:**
- Covers Windows/Linux in addition to macOS
- Large ecosystem of web components

**Cons:**
- Rewrites entire frontend
- Loses SwiftUI investment
- Performance overhead
- Can't share Swift code

**Decision:** Rejected. Too much work for MVP, loses code sharing benefits.

## Risks & Mitigations

### 1. SwiftUI Behavior Differences

**Risk:** Some SwiftUI views may render or behave differently on macOS.

**Mitigation:**
- NavigationStack works on both platforms
- Test each view on macOS during implementation
- Use `#if os(macOS)` for platform-specific adjustments if needed

### 2. Speech Recognition Availability

**Risk:** `SFSpeechRecognizer` may have different capabilities on macOS.

**Mitigation:**
- SFSpeechRecognizer is available on macOS 10.15+
- Test speech recognition early in implementation
- Graceful degradation: disable voice input if unavailable

### 3. App Sandbox Restrictions

**Risk:** macOS sandbox may block functionality that works on iOS.

**Mitigation:**
- Request necessary entitlements upfront (network, microphone, file access)
- Test file operations (resource sharing) with sandbox enabled
- Document required entitlements

### 4. CoreData Migration

**Risk:** Shared CoreData model may have migration issues across platforms.

**Mitigation:**
- Use same model version on both platforms
- Test data persistence on macOS
- CoreData container location differs; ensure both targets use appropriate paths

### Rollback Strategy

1. macOS target is additive; iOS target unchanged
2. If macOS issues arise, simply don't ship macOS version
3. Conditional compilation ensures iOS code path unaffected
4. Can revert to iOS-only by removing VoiceCodeMac target from project.yml

## Implementation Order

1. Create `VoiceCodeMac/` directory with Info.plist and entitlements
2. Update `project.yml` with macOS target and test exclusions
3. Add platform conditionals to `VoiceCodeClient.swift` (lifecycle notifications)
4. Add platform conditionals to `VoiceInputManager.swift` (AVAudioSession)
5. Add platform conditionals to `VoiceOutputManager.swift` (audio session, background playback properties)
6. Add platform conditionals to `VoiceCodeApp.swift` (lifecycle notifications)
7. Create `ClipboardUtility.swift` with cross-platform clipboard/haptic helpers
8. Update 7 view files to use `ClipboardUtility`:
   - `DirectoryListView.swift`
   - `SessionsForDirectoryView.swift`
   - `SessionLookupView.swift`
   - `SessionInfoView.swift`
   - `ConversationView.swift`
   - `DebugLogsView.swift`
   - `CommandOutputDetailView.swift`
9. Add macOS icons to Assets.xcassets
10. Run `xcodegen generate`
11. Build macOS target and fix compilation errors
12. Run `VoiceCodeMacTests` and verify tests pass
13. Manual testing of all features on macOS
