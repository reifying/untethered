# BlueParrott B450-XT Headset Integration

Recommendation document for hands-free AI conversation control via the BlueParrott B450-XT Mono Bluetooth headset, targeting both the VoiceCode Mac app and the Untethered iOS app.

**Goal:** Full back-and-forth AI conversation using only headset buttons — no phone or computer interaction required.

**Corporate constraint:** Only the Mac desktop app is permitted. The iOS app is secondary/personal use.

---

## 1. Current State

### Mac App (VoiceCode)

**Audio input:** `AVAudioEngine` + `SFSpeechRecognizer` for on-device speech-to-text.
- `VoiceInputManager.swift` — `startRecording()` / `stopRecording()` manage the audio engine lifecycle
- macOS path skips explicit `AVAudioSession` config; `AVAudioEngine` handles routing automatically

**Audio output:** `AVSpeechSynthesizer` via `VoiceOutputManager.swift`
- Mute toggle persisted in UserDefaults, toggled via `Cmd+Shift+M`
- `pause()` / `resume()` / `stop()` are all wired up
- Session affinity: TTS auto-cancels when user switches sessions

**Input triggers:**
- **Push-to-talk:** `Option+Space` hold-to-talk via `PushToTalkModifier.swift` — uses SwiftUI `onKeyPress`, which only fires when the app window is focused
- **MenuBar:** Space key or click toggles recording in the menu bar popover
- **Keyboard shortcuts:** `Cmd+.` stop speaking, `Cmd+Shift+M` mute, `Cmd+K` command palette

**What's missing:**
- No media key / remote control handling (`MPRemoteCommandCenter`, `NowPlayingInfoCenter` — none)
- No global hotkey capture (`NSEvent.addGlobalMonitorForEvents` — none)
- No HID device monitoring (`IOKit` — none)
- No Bluetooth-specific code at all
- No CoreAudio device property monitoring
- The `onKeyPress` PTT only works when the app window is focused — completely useless for away-from-desk use

**Sandbox:** The Mac app is sandboxed with `com.apple.security.device.audio-input` and `com.apple.security.network.client`. This constrains some approaches (see section 3).

### iOS App (Untethered)

**Audio input:** `@react-native-voice/voice` native module using `AVAudioEngine` + `SFSpeechRecognizer`.
- Native `Voice.m` has Bluetooth detection: `isHeadsetPluggedIn()` checks for `AVAudioSessionPortBluetoothA2DP`, `isHeadSetBluetooth()` checks for `AVAudioSessionPortBluetoothHFP`
- Audio session auto-configures `AVAudioSessionCategoryOptionAllowBluetooth` when a Bluetooth headset is detected
- Tap-to-start / tap-to-stop pattern (not hold-to-talk)

**Audio output:** `react-native-tts` via `AVSpeechSynthesizer`
- Silent switch respect, background keep-alive timer (25s silent audio pulses)
- `UIBackgroundModes: audio` enabled in Info.plist

**Voice lifecycle:** Re-frame event system in `voice/events.cljs`
- Auto-send: when speech ends, transcript is automatically sent as a `supervisor_message` via WebSocket
- Mutual exclusion: recording and TTS never overlap (enforced at both db and effect levels)
- TTS auto-cancel before recording starts (150ms delay for audio session handoff)

**What's missing:**
- No `MPRemoteCommandCenter` — cannot receive headset button presses
- No `MPNowPlayingInfoCenter` — not registered as "now playing" app
- No `UIEvent.remoteControlReceived` handling
- The existing Bluetooth detection only affects audio routing, not button event capture

### Backend

**No audio involvement.** The backend receives transcribed text via WebSocket `prompt` messages and returns AI responses. Audio is entirely client-side.

**Relevant protocol:**
- `prompt` message (text field) — initiates a turn
- `kill_session` — only way to abort a turn mid-stream (hard kill, no graceful interrupt)
- `turn_complete` — broadcast when the AI finishes responding
- `supervisor_message` — used by iOS for voice input (same as prompt, but through supervisor flow)

**No backend changes needed** for headset integration.

---

## 2. BlueParrott B450-XT Capabilities

### Physical Controls

| Control | Default Behavior | Bluetooth Signal | Programmable? |
|---------|-----------------|------------------|---------------|
| **PTT button** (boom arm) | Mic mute/unmute toggle | HFP SCO mute state change | Yes, via BlueParrott app |
| **Volume Up** | Volume increase | AVRCP volume up / HID Consumer Control | No |
| **Volume Down** | Volume decrease | AVRCP volume down / HID Consumer Control | No |
| **MFB** (multifunction) | Play/pause, answer/end call | AVRCP play/pause, HFP call control | Limited (call/music modes) |
| **ANC toggle** | Toggle noise cancellation | Internal only | No, not software-visible |

### PTT Button Programming (via BlueParrott app)

The PTT button can be configured to:
1. **Mute** (default) — toggles HFP microphone mute. Operates at Bluetooth profile level.
2. **Speed Dial** — sends HFP telephony command
3. **Custom Button** — sends vendor-specific HID usage page report (0xFF00)

### What macOS Sees

- **MFB play/pause:** Arrives as a system media key event (`NX_KEYTYPE_PLAY`). Routed to the active `MPRemoteCommandCenter` registrant, or to the frontmost app via `NSEvent` system-defined events.
- **Volume buttons:** Handled by macOS system volume control. Apps can observe volume changes via CoreAudio but cannot intercept the buttons themselves.
- **PTT mute/unmute:** Changes the mute property of the Bluetooth input device. Observable via CoreAudio's `AudioObjectAddPropertyListener` on `kAudioDevicePropertyMute` for the input device.
- **PTT as custom button:** Sends a vendor HID report. Receivable via `IOKit` HID API — but **not available in sandboxed apps** without the `com.apple.security.device.usb` entitlement (which Apple does not grant for App Store apps).

### What iOS Sees

- **MFB play/pause:** Routed through `MPRemoteCommandCenter` to the app that registered as the "now playing" app. Falls through to the system if no app has registered.
- **Volume buttons:** System-level volume control. iOS does not permit interception.
- **PTT mute/unmute:** Operates at the HFP profile level. The app can detect mute state changes via `AVAudioSession` route/configuration change notifications.

### Bluetooth Range

The B450-XT is **Bluetooth Class 1** (up to ~100m / 300ft line of sight). With walls, expect ~20-30m reliably. This is significantly better than the typical ~10m of Class 2 devices, making the away-from-desk workflow viable within an office or home.

---

## 3. Recommended Features — Mac (Prioritized)

### P0: MPRemoteCommandCenter Integration (Media Button → PTT)

**What:** Register the Mac app with `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` so the MFB play/pause button on the headset toggles recording.

**Why this first:** This is the single change that enables hands-free conversation. It works in the sandbox, works when the app is not frontmost, and uses the button (MFB) that already sends a standard media key.

**API surface:**
```swift
import MediaPlayer

// Register as "now playing" app
MPNowPlayingInfoCenter.default().playbackState = .paused
MPNowPlayingInfoCenter.default().nowPlayingInfo = [
    MPMediaItemPropertyTitle: "VoiceCode",
    MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
    MPMediaItemPropertyPlaybackDuration: 0
]

// Handle play/pause = toggle recording
let commandCenter = MPRemoteCommandCenter.shared()
commandCenter.togglePlayPauseCommand.addTarget { event in
    // Toggle recording
    return .success
}
commandCenter.playCommand.addTarget { event in
    // Start recording
    return .success
}
commandCenter.pauseCommand.addTarget { event in
    // Stop recording, send transcription
    return .success
}
```

**Implementation:**
1. Create `HeadsetRemoteCommandManager.swift` — owns the `MPRemoteCommandCenter` registration, holds a reference to `VoiceInputManager` and `VoiceCodeClient`
2. On play/togglePlayPause: if not recording → `voiceInput.startRecording()`, update now-playing state to "playing" (recording indicator)
3. On pause/togglePlayPause: if recording → `voiceInput.stopRecording()`, grab transcription, auto-send via `client.sendQuickPrompt()` or `client.sendPrompt()`, update now-playing state to "paused"
4. Update `MPNowPlayingInfoCenter` to show current state (recording / waiting / speaking) — this makes the headset's LED/status indicator reflect app state
5. Wire into `VoiceCodeApp.swift` — instantiate at app launch, keep alive for app lifetime
6. Add entitlement: none needed — `MediaPlayer` framework works in sandbox

**Files to modify:**
- New: `ios/VoiceCode/Managers/HeadsetRemoteCommandManager.swift`
- Modified: `ios/VoiceCode/VoiceCodeApp.swift` (instantiate manager)

**Sandbox note:** `MPRemoteCommandCenter` works in sandboxed Mac apps. The key requirement is that the app must set `MPNowPlayingInfoCenter.default().playbackState` to claim the now-playing slot. Only one app at a time owns this slot — if the user starts playing music in Spotify, VoiceCode loses the headset button. This is acceptable for the conversational use case; a setting to "claim now-playing on launch" vs. "only when explicitly enabled" would handle the edge case.

**Risk:** If another app (Spotify, Apple Music) claims the now-playing slot, the headset buttons route to that app instead. Mitigation: add a "Reclaim headset" menu item / keyboard shortcut that re-registers. Also consider re-claiming automatically when VoiceCode detects it lost the slot.

**Complexity:** Low-medium. The API is straightforward; the main work is wiring it into the existing voice input/output lifecycle and handling the now-playing contention.

### P1: Auto-Send and Auto-Speak Loop

**What:** When recording stops (via headset button), automatically send the transcription to the active session and speak the response aloud — creating a continuous conversation loop with no screen interaction.

**Why:** Without this, the user would have to look at the screen to hit "Send" after recording. The iOS app already does this (auto-send on speech end at `voice/events.cljs:192-199`). The Mac app's MenuBar flow requires clicking "Send" or pressing Return.

**Implementation:**
1. Add an `autoSendOnRecordingStop` setting to `AppSettings` (default: true when headset mode is active)
2. Modify the `HeadsetRemoteCommandManager` pause handler to call `sendPrompt()` immediately after stopping recording, skipping the "review transcription" step
3. Add an `autoSpeakResponses` setting (probably already exists — check `AppSettings`)
4. Ensure `VoiceCodeClient` triggers `VoiceOutputManager.speak()` when a `turn_complete` arrives with response text (for the active/subscribed session)

**Files to modify:**
- `ios/VoiceCode/Managers/HeadsetRemoteCommandManager.swift` (from P0)
- `ios/VoiceCode/Managers/VoiceCodeClient.swift` (auto-speak on turn_complete)
- `ios/VoiceCode/Views/MacSettingsView.swift` (settings toggle)

**Complexity:** Low. Mostly wiring existing capabilities together.

### P2: CoreAudio PTT Mute Detection

**What:** Monitor the Bluetooth input device's mute state via CoreAudio to use the BlueParrott's dedicated PTT button (not just the MFB).

**Why:** The PTT button is the most ergonomic control on the headset — it's large, on the boom arm, and designed for push-to-talk. The MFB (P0) works but is a small side button. Using the PTT button as the primary trigger is the end-state experience.

**API surface:**
```swift
import CoreAudio

// Find the Bluetooth input device
var address = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyMute,
    mScope: kAudioDevicePropertyScopeInput,
    mElement: kAudioObjectPropertyElementMain
)

// Add listener for mute state changes
AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main) { _, _ in
    var muted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
    if muted == 0 {
        // PTT pressed (unmuted) → start recording
    } else {
        // PTT released (muted) → stop recording
    }
}
```

**Implementation:**
1. Create `BluetoothAudioMonitor.swift` — monitors CoreAudio device property changes
2. Enumerate audio devices, find connected Bluetooth input devices
3. Listen for `kAudioDevicePropertyMute` changes on the input scope
4. Also listen for `kAudioHardwarePropertyDevices` to detect when the headset connects/disconnects
5. Wire mute-off → start recording, mute-on → stop recording (same lifecycle as P0, different trigger)
6. Coordinate with P0 so both triggers (MFB play/pause and PTT mute) work simultaneously

**Files to create:**
- `ios/VoiceCode/Managers/BluetoothAudioMonitor.swift`

**Sandbox note:** CoreAudio `AudioObjectAddPropertyListenerBlock` is available in sandboxed apps when the app has the `com.apple.security.device.audio-input` entitlement (already present). No additional entitlements needed.

**BlueParrott PTT configuration:** The headset should be configured with PTT = Mute (the default). This gives momentary push-to-talk behavior when the user holds the button, or toggle behavior when tapped. The BlueParrott app lets the user choose between toggle and momentary modes — **recommend momentary mode** for the most natural push-to-talk experience.

**Complexity:** Medium. CoreAudio device enumeration and property listening is well-documented but requires careful handling of device connect/disconnect, multiple audio devices, and distinguishing the BlueParrott from other input devices.

### P3: Headset-Aware Audio Routing

**What:** Automatically route audio input and output through the Bluetooth headset when it connects, and fall back to built-in devices when it disconnects.

**Why:** Currently the Mac app uses whatever `AVAudioEngine` default input is. If the user has multiple audio devices, the headset might not be selected. Explicit routing ensures the headset is always used when available.

**Implementation:**
1. In `BluetoothAudioMonitor.swift` (from P2), detect when a Bluetooth audio device connects
2. Set the `AVAudioEngine` input device to the Bluetooth device via CoreAudio:
   ```swift
   AudioObjectSetPropertyData(engineDeviceID, &inputSourceAddress, ...)
   ```
3. For TTS output, `AVSpeechSynthesizer` on macOS routes through the system default output. To force output through the headset, set the system default output device (heavy-handed) or use `AVAudioEngine` for TTS output instead of `AVSpeechSynthesizer` (significant refactor)
4. Simpler alternative: document that the user should set the headset as system default input/output in System Settings → Sound when using headset mode. macOS remembers this preference per-device.

**Complexity:** Low if we just document the System Settings requirement. Medium-high if we want automatic routing, because `AVSpeechSynthesizer` doesn't support explicit output device selection on macOS.

### P4: Interrupt via Volume Button or Second MFB Press

**What:** Map a headset button to interrupt/cancel the current AI response (equivalent to `Cmd+.` stop speaking, or `kill_session` to abort a turn).

**Why:** In a hands-free conversation, the user needs a way to say "stop, I don't need to hear the rest" without waiting for TTS to finish.

**Implementation options:**
- **Option A (recommended):** Double-press MFB (play/pause twice quickly) → stop TTS. This reuses the P0 infrastructure. Detect double-tap in `HeadsetRemoteCommandManager` with a short debounce timer (~400ms).
- **Option B:** `nextTrackCommand` / `previousTrackCommand` in `MPRemoteCommandCenter` — the MFB sends these on long-press. Map next-track → stop speaking, previous-track → kill session.
- **Option C:** Volume button events via CoreAudio — possible but interferes with actual volume control.

**Files to modify:**
- `ios/VoiceCode/Managers/HeadsetRemoteCommandManager.swift`

**Complexity:** Low (option A or B). The interrupt logic already exists (`voiceOutput.stop()`, `client.sendKillSession()`).

---

## 4. Recommended Features — iOS (Prioritized)

### P0: MPRemoteCommandCenter Registration

**What:** Register Untethered as the "now playing" app on iOS to receive headset button events.

**Why:** Same rationale as Mac P0. Without this, the MFB play/pause and PTT buttons on the headset do nothing useful in Untethered.

**Implementation:**
1. Create a new native module `HeadsetRemoteManager` (Obj-C or Swift)
2. Register with `MPRemoteCommandCenter`:
   - `togglePlayPauseCommand` → dispatch `:voice/toggle-recording` to re-frame
   - `playCommand` → dispatch `:voice/start-listening`
   - `pauseCommand` → dispatch `:voice/stop-listening`
3. Set `MPNowPlayingInfoCenter` info to claim the now-playing slot
4. Bridge to ClojureScript via React Native native module / event emitter
5. Add `MPNowPlayingInfoPropertyElapsedPlaybackTime` updates during TTS playback so the headset shows progress

**Files to create:**
- `frontend/ios/VoiceCodeMobile/HeadsetRemoteManager.m` (or `.swift` with bridging header)

**Files to modify:**
- `frontend/src/untethered/voice/events.cljs` — add event handler for headset button events
- `frontend/src/untethered/core.cljs` — initialize headset manager on mount

**Complexity:** Medium. The native module bridge adds some ceremony, but the iOS `MPRemoteCommandCenter` API is simpler than the Mac equivalent because iOS has a single audio session model.

**Note:** Since the iOS app already auto-sends transcriptions on speech end (`voice/events.cljs:192-199`) and already handles Bluetooth audio routing (`Voice.m:36-41`), P0 is the only change needed for a complete hands-free loop on iOS.

### P1: AVAudioSession Route Change Handling for PTT

**What:** Detect BlueParrott PTT mute/unmute via `AVAudioSessionRouteChangeNotification` or `AVAudioSession.interruptionNotification`.

**Why:** Same as Mac P2 — the PTT button is more ergonomic than the MFB.

**Implementation:**
1. In the native `Voice.m` module (or a new native module), register for `AVAudioSessionRouteChangeNotification`
2. On route change, check if the input port's mute state changed
3. Bridge mute state changes to JS via `RCTEventEmitter`

**Caveat:** iOS's `AVAudioSession` does not expose a direct per-device mute property the way CoreAudio does on macOS. The PTT mute on HFP may manifest as an audio interruption or route change rather than a discrete mute property. Testing with the actual hardware is required to determine the exact notification behavior.

**Complexity:** Medium-high due to uncertainty about iOS's exposure of HFP mute state.

### P2: Background Audio Session Persistence

**What:** Keep the audio session alive when the app is backgrounded so headset buttons continue to work.

**Why:** iOS suspends apps aggressively. The `UIBackgroundModes: audio` is already declared, but the app needs an active audio session (playing or recording) to stay alive. The existing 25s silent audio keep-alive timer (`voice/tts.cljs:31-52`) only runs during TTS. For headset mode, it needs to run continuously.

**Implementation:**
1. When headset mode is active, start the silent keep-alive timer regardless of TTS state
2. Register with `MPNowPlayingInfoCenter` to appear in Control Center (visual confirmation for user)
3. Handle `AVAudioSession.interruptionNotification` to recover from phone calls, Siri, etc.

**Complexity:** Low. The infrastructure exists; just needs to run more broadly.

---

## 5. Away-From-Desk Mac Workflow

### Prerequisites

1. BlueParrott B450-XT paired with Mac via Bluetooth
2. PTT button configured to **Mute** mode (default) with **momentary** (push-to-talk) behavior via BlueParrott app
3. Mac set to use BlueParrott as input/output audio device (System Settings → Sound)
4. VoiceCode Mac app running with an active session connected to the backend
5. Mac configured to not sleep while on power (System Settings → Energy → Prevent automatic sleeping)
6. "Headset mode" enabled in VoiceCode settings (enables auto-send + auto-speak + now-playing registration)

### Conversation Flow

```
 User Action                    System Response
 ─────────────────────────────  ──────────────────────────────────────────
 Press MFB (play/pause)         Mac app starts recording via headset mic
   or hold PTT button           SFSpeechRecognizer transcribes in real-time

 Speak: "What's the status      Partial transcription streams to
 of the auth migration?"        VoiceInputManager.transcribedText

 Press MFB again                Mac app stops recording
   or release PTT button        Transcription auto-sent to active session
                                via VoiceCodeClient.sendPrompt()
                                Now-playing state: "Processing..."

 [wait ~5-30s]                  Backend processes prompt via Claude/etc.
                                turn_complete received via WebSocket

                                VoiceOutputManager.speak() reads response
                                through headset speakers
                                Now-playing state: "Speaking"

 [listen to response]           Response plays through headset

 Response finishes              Now-playing state: "Ready"
                                Ready for next turn

 Press MFB to start next turn   Cycle repeats
```

### Interrupt Flow

```
 User Action                    System Response
 ─────────────────────────────  ──────────────────────────────────────────
 [AI is speaking a long reply]

 Double-press MFB               VoiceOutputManager.stop() called
   or press PTT briefly         TTS stops immediately
                                Now-playing state: "Ready"

 Press MFB to ask follow-up     New recording starts, cycle continues
```

### State Machine

```
                  ┌─────────────────────────────────────┐
                  │                                     │
                  ▼                                     │
              ┌───────┐   MFB press    ┌───────────┐   │
              │ READY │──────────────▶│ RECORDING │   │
              └───────┘               └───────────┘   │
                  ▲                        │           │
                  │                   MFB press /      │
                  │                   PTT release       │
                  │                        │           │
                  │                        ▼           │
                  │                  ┌──────────┐      │
                  │                  │ SENDING  │      │
                  │                  └──────────┘      │
                  │                        │           │
                  │                  turn_complete      │
                  │                        │           │
                  │    speech done         ▼           │
                  │◀──────────────── ┌──────────┐      │
                  │                  │ SPEAKING │      │
                  │                  └──────────┘      │
                  │                        │           │
                  │                   double-MFB       │
                  │                   (interrupt)      │
                  │                        │           │
                  └────────────────────────┘           │
                                                       │
                  ┌──────────────────────────┐         │
                  │ headset disconnects      │─────────┘
                  │ → pause, wait reconnect  │
                  └──────────────────────────┘
```

### Range and Reliability

- B450-XT is Bluetooth Class 1: ~100m line of sight, ~20-30m through walls
- macOS Bluetooth range depends on the Mac's radio (Class 1 on most Macs)
- Audio quality over HFP/SCO is 8kHz mono (telephony quality) — acceptable for speech but not music. `SFSpeechRecognizer` handles this fine.
- If the headset goes out of range, macOS will drop the connection. The app should detect disconnection (CoreAudio device removal notification) and pause gracefully. On reconnection, resume to READY state.

### Mac Sleep Prevention

The Mac must stay awake for this to work. Options:
1. **Amphetamine** (App Store app) — keeps Mac awake while specific app is running
2. **`caffeinate -i`** — terminal command, prevents idle sleep
3. **System Settings** — disable sleep on power adapter
4. **App-level assertion:** `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep, ...)` — the app itself prevents sleep. Requires removing sandbox or adding `com.apple.security.temporary-exception.iokit-user-client-class` entitlement (not recommended for App Store).

**Recommendation:** Document the Amphetamine / caffeinate approach rather than adding sleep prevention to the app itself. Keep the app's sandbox clean.

---

## 6. Implementation Sequence

### Phase 1: Core Hands-Free Loop (Mac)

Build the minimum viable headset experience.

1. **Mac P0: MPRemoteCommandCenter** — `HeadsetRemoteCommandManager.swift`
   - Register play/pause/toggle handlers
   - Wire to `VoiceInputManager.startRecording()` / `stopRecording()`
   - Set now-playing info

2. **Mac P1: Auto-Send + Auto-Speak** — close the loop
   - On recording stop → auto-send transcription to active session
   - On turn_complete → auto-speak response
   - Add "Headset Mode" toggle in settings

**After Phase 1:** Travis can have a full conversation using only the MFB (play/pause) button. This covers the corporate constraint (Mac-only).

### Phase 2: PTT Button Support (Mac)

Upgrade from MFB to the ergonomic PTT button.

3. **Mac P2: CoreAudio PTT Mute Detection** — `BluetoothAudioMonitor.swift`
   - Monitor Bluetooth input device mute property
   - PTT unmute → start recording, PTT mute → stop recording
   - Handle device connect/disconnect

**After Phase 2:** Travis can use the large, convenient PTT button instead of the small MFB.

### Phase 3: Polish (Mac)

4. **Mac P4: Interrupt support** — double-tap MFB or next-track command stops TTS
5. **Mac P3: Audio routing awareness** — detect headset connection, show status in menu bar
6. Add "Headset connected" / "Headset disconnected" indicators to menu bar icon
7. Settings UI for headset behavior (auto-claim now-playing, PTT mode toggle vs momentary, auto-send, auto-speak)

### Phase 4: iOS (if desired)

8. **iOS P0: MPRemoteCommandCenter** — native module for headset button events
9. **iOS P2: Background session persistence** — continuous keep-alive
10. **iOS P1: PTT mute detection** — if hardware testing confirms iOS exposes HFP mute state

---

## Appendix: Key Files Reference

### Mac App

| File | Role |
|------|------|
| `ios/VoiceCode/VoiceCodeApp.swift` | App entry, scene/command registration |
| `ios/VoiceCode/Managers/VoiceInputManager.swift` | AVAudioEngine + SFSpeechRecognizer |
| `ios/VoiceCode/Managers/VoiceOutputManager.swift` | AVSpeechSynthesizer TTS |
| `ios/VoiceCode/Managers/VoiceCodeClient.swift` | WebSocket client, `sendPrompt()`, `sendQuickPrompt()` |
| `ios/VoiceCode/Utils/PushToTalkModifier.swift` | Option+Space PTT (app-focused only) |
| `ios/VoiceCode/MenuBarExtra.swift` | Menu bar quick-capture UI |
| `ios/VoiceCode/Views/MacSettingsView.swift` | Mac settings tabs |
| `ios/VoiceCodeMac/VoiceCodeMac.entitlements` | Sandbox entitlements |

### iOS App

| File | Role |
|------|------|
| `~/code/untethered/frontend/src/untethered/voice/events.cljs` | Voice lifecycle event handlers |
| `~/code/untethered/frontend/src/untethered/voice/recognition.cljs` | Speech recognition wrapper |
| `~/code/untethered/frontend/src/untethered/voice/tts.cljs` | TTS wrapper + keep-alive |
| `~/code/untethered/frontend/src/untethered/core.cljs` | PTT button UI |
| `~/code/untethered/frontend/node_modules/@react-native-voice/voice/ios/Voice/Voice.m` | Native audio/BT handling |

### Backend

| File | Role |
|------|------|
| `backend/src/voice_code/server.clj` | WebSocket message dispatch |
| `docs/protocol/websocket-protocol.md` | Protocol specification |

---

## Appendix: BlueParrott App Configuration

For optimal VoiceCode integration, configure the BlueParrott B450-XT via the BlueParrott app:

1. **PTT Button Mode:** Mute (default)
2. **PTT Button Behavior:** Momentary (push-to-talk, not toggle)
3. **ANC:** User preference (does not affect software integration)

The momentary PTT mode maps cleanly to "hold to record, release to send" — the most natural interaction for voice input. If the user prefers tap-to-start/tap-to-stop, toggle mode also works with the CoreAudio mute detection (Phase 2).
