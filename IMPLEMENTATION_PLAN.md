# Voice-Code Implementation Plan

**Timeline: 2-3 weeks for MVP**

Based on comprehensive design review, this plan focuses on a minimal viable prototype that demonstrates the core voice-controlled coding workflow.

## Scope: MVP vs. Future Enhancements

### ✅ In Scope for MVP (2-3 weeks)

**Core Functionality:**
- Voice input (Apple Speech Framework) and output (AVSpeechSynthesizer)
- Text input option (for pasting code/URLs)
- Basic session management (one session = one working directory)
- Simple conversation history (no nested threads in v1)
- Clojure WebSocket server
- Claude Code CLI integration via subprocess
- Tailscale VPN connectivity
- Server configuration UI

**Technical Requirements:**
- Async Claude invocation (non-blocking)
- Basic error handling and timeouts
- Session state synchronization between iPhone and backend
- Reconnection logic for WebSocket

### ❌ Out of Scope for MVP (Future v2+)

- Thread organization within sessions (too complex for v1)
- Voice replay per message (start with auto-play only)
- Streaming responses (will use blocking with timeout)
- Rate limiting (rely on Tailscale security)
- Backend session persistence (in-memory for v1)
- Complex state management (cleanup scheduler, circular buffers)
- Battery profiling (manual testing sufficient for v1)

### ⚡ High Priority Enhancement (Parallel Track)

- **clojure-mcp integration**: REPL-driven development for Clojure projects (P1)
  - Can be worked on independently after basic backend setup
  - Enhances Claude's ability to work with Clojure code
  - Not blocking for core voice functionality

---

## Critical Fixes from Design Review

### 1. Async Claude Invocation ⚠️ CRITICAL

**Problem:** Blocking I/O in WebSocket handler freezes the connection.

**Solution:**
```clojure
(ns voice-code.websocket.server
  (:require [clojure.core.async :as async]))

(defn handle-websocket-message
  [channel session-state msg]
  (try
    (let [data (json/parse-string msg true)]
      (case (:type data)
        "prompt"
        (let [prompt (:text data)
              session-id (:session_id data)  ; From message, not state!
              working-dir (:working_directory data)]

          ;; Launch async
          (async/go
            (let [response-ch (async/thread
                                (claude/invoke-claude
                                  prompt
                                  :session-id session-id
                                  :working-directory working-dir))

                  ;; Wait with timeout (5 minutes)
                  [response port] (async/alts!
                                    [response-ch
                                     (async/timeout 300000)])]

              (if (= port response-ch)
                ;; Success - send response
                (do
                  (when (:success response)
                    (swap! session-state assoc :session-id (:session-id response)))
                  (http/send! channel (json/generate-string response)))

                ;; Timeout
                (http/send! channel
                  (json/generate-string
                    {:success false
                     :error "Request timed out after 5 minutes"})))))

          ;; Immediate ack
          (json/generate-string {:type "ack"}))

        "ping"
        (json/generate-string {:type "pong"})

        (json/generate-string {:type "error" :message "Unknown message type"})))

    (catch Exception e
      (log/error e "Error handling message")
      (json/generate-string {:type "error" :message (ex-message e)}))))
```

### 2. Session State Synchronization ⚠️ CRITICAL

**Problem:** iPhone tracks sessions, backend tracks Claude session IDs - they can get out of sync.

**Solution:** Backend is stateless per request - iPhone sends everything needed:

```swift
// iPhone sends full context in every message
func sendPrompt(_ text: String, sessionId: String? = nil, workingDirectory: String? = nil) {
    var message: [String: Any] = [
        "type": "prompt",
        "text": text
    ]

    if let sessionId = sessionId {
        message["session_id"] = sessionId
    }

    if let workingDirectory = workingDirectory {
        message["working_directory"] = workingDirectory
    }

    // Send message...
}

// Backend extracts from message and returns updated session ID
// iPhone updates local session with new ID from response
```

### 3. Error Handling ⚠️ CRITICAL

**iPhone side:**
```swift
class VoiceCodeClient: ObservableObject {
    @Published var isConnected = false
    @Published var currentResponse = ""
    @Published var currentError: String?
    @Published var sessionId: String?

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        DispatchQueue.main.async {
            if let type = json["type"] as? String {
                switch type {
                case "response":
                    if let success = json["success"] as? Bool, success {
                        self.currentResponse = json["text"] as? String ?? ""
                        self.sessionId = json["session_id"] as? String
                        self.currentError = nil
                    } else {
                        self.currentError = json["error"] as? String ?? "Unknown error"
                    }

                case "error":
                    self.currentError = json["message"] as? String ?? "Unknown error"

                default:
                    break
                }
            }
        }
    }
}
```

### 4. WebSocket Reconnection ⚠️ CRITICAL

**iPhone side:**
```swift
class VoiceCodeClient: ObservableObject {
    // ... existing code ...

    private var reconnectionTimer: Timer?

    func setupReconnection() {
        reconnectionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.isConnected {
                print("Attempting reconnection...")
                self.connect()
            }
        }
    }

    func connect() {
        // ... existing connection code ...
        setupReconnection()
    }

    deinit {
        reconnectionTimer?.invalidate()
    }
}
```

### 5. Audio Session Management ⚠️ HIGH PRIORITY

**iPhone side:**
```swift
class VoiceOutputManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    // ... existing code ...

    func speak(_ text: String) {
        // Configure audio session for playback
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5

        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Reset audio session
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }
}
```

---

## Simplified Architecture for MVP

### Backend (Clojure)

**Minimal deps.edn:**
```clojure
{:paths ["src" "resources"]
 :deps {org.clojure/clojure {:mvn/version "1.12.3"}
        org.clojure/core.async {:mvn/version "1.7.701"}
        org.clojure/tools.logging {:mvn/version "1.3.0"}

        ;; HTTP & WebSocket
        http-kit/http-kit {:mvn/version "2.8.1"}

        ;; JSON
        cheshire/cheshire {:mvn/version "6.1.0"}

        ;; Logging
        com.taoensso/timbre {:mvn/version "6.6.1"}}}
```

**Simplified structure:**
```
voice-code/
├── src/
│   └── voice_code/
│       ├── server.clj          # Main entry + WebSocket handler
│       └── claude.clj           # Claude CLI invocation
├── resources/
│   └── config.edn               # Server config (port, etc.)
└── deps.edn
```

### iPhone App (Swift)

**Simplified structure:**
```
VoiceCode/
├── Models/
│   ├── Message.swift           # User/assistant messages
│   └── Session.swift           # Working directory + Claude session ID
├── Managers/
│   ├── VoiceCodeClient.swift   # WebSocket client
│   ├── VoiceInputManager.swift # Speech-to-text
│   ├── VoiceOutputManager.swift # Text-to-speech
│   ├── SessionManager.swift    # Session persistence
│   └── AppSettings.swift       # Server configuration
├── Views/
│   ├── ContentView.swift       # Main UI
│   ├── MessageView.swift       # Message bubble
│   ├── SessionsView.swift      # Session picker
│   └── SettingsView.swift      # Server config
└── VoiceCodeApp.swift          # App entry point
```

---

## 3-Week Implementation Schedule

### Week 1: Backend Foundation

**Days 1-2: Project Setup**
- [ ] Initialize Clojure project with minimal deps.edn
- [ ] Set up http-kit WebSocket server
- [ ] Basic message routing (ping/pong, prompt)
- [ ] Manual testing with `wscat` or similar

**Days 3-4: Claude CLI Integration**
- [ ] Implement Claude CLI invocation function
- [ ] Add async wrapper with core.async
- [ ] Add timeout handling (5 minutes)
- [ ] Parse JSON responses from Claude CLI
- [ ] Error handling for CLI failures

**Day 5: Testing & Polish**
- [ ] Test with real Claude Code CLI
- [ ] Test session resumption with `--resume`
- [ ] Test working directory switching
- [ ] Fix any issues discovered
- [ ] Write basic unit tests

**Parallel Track (can start after Day 1):**
- [ ] Set up clojure-mcp with nREPL server (voice-code-45)
- [ ] Add :nrepl and :mcp aliases to deps.edn
- [ ] Test Claude Code can discover MCP tools
- [ ] Verify REPL-driven development workflow

### Week 2: iPhone App

**Days 1-2: Core UI & WebSocket**
- [ ] Create SwiftUI project
- [ ] Implement WebSocket client with reconnection
- [ ] Build main UI layout (message list, input area)
- [ ] Add settings view for server configuration
- [ ] Test connection to backend

**Days 3-4: Voice Integration**
- [ ] Implement speech-to-text (Apple Speech Framework)
- [ ] Request microphone permissions
- [ ] Implement text-to-speech (AVSpeechSynthesizer)
- [ ] Fix audio session management
- [ ] Add push-to-talk UI

**Day 5: Session Management**
- [ ] Implement Session model with Codable
- [ ] Add SessionManager with UserDefaults persistence
- [ ] Build SessionsView for switching sessions
- [ ] Connect sessions to WebSocket messages
- [ ] Test session persistence across app restarts

### Week 3: Integration & Polish

**Days 1-2: End-to-End Testing**
- [ ] Set up Tailscale on server and iPhone
- [ ] Test full voice workflow: speak → Claude → listen
- [ ] Test text input workflow
- [ ] Test session switching
- [ ] Test error scenarios (network drop, timeout, etc.)

**Days 3-4: Bug Fixes & UX**
- [ ] Fix issues discovered in testing
- [ ] Improve error messages
- [ ] Add loading indicators
- [ ] Polish UI transitions
- [ ] Test on different iPhone models/iOS versions

**Day 5: Documentation & Handoff**
- [ ] Write setup instructions (Tailscale, server start, etc.)
- [ ] Document known limitations
- [ ] Create troubleshooting guide
- [ ] Record demo video
- [ ] Tag v0.1.0 release

---

## Testing Checklist

### Backend Tests
- [ ] WebSocket connection establishment
- [ ] Message parsing and routing
- [ ] Claude CLI invocation with various prompts
- [ ] Session resumption with `--resume` flag
- [ ] Working directory switching
- [ ] Timeout handling (use sleep in test CLI)
- [ ] Error handling for malformed messages
- [ ] Concurrent requests (multiple clients)

### iPhone App Tests
- [ ] WebSocket connection and reconnection
- [ ] Voice input (short prompt, long prompt)
- [ ] Text input (short text, long text, paste)
- [ ] Voice output (short response, long response)
- [ ] Session creation and switching
- [ ] Settings persistence
- [ ] Error display (timeout, network error, Claude error)
- [ ] Background/foreground transitions
- [ ] Different network conditions (WiFi, cellular, switching)

### Integration Tests
- [ ] Full voice round-trip: speak → Claude processes → hear response
- [ ] Text input with code snippet pasted
- [ ] Session resumption (multiple messages in same session)
- [ ] Working directory switching between projects
- [ ] Network drop recovery (disconnect Tailscale mid-conversation)
- [ ] Server restart recovery
- [ ] Long-running Claude request (>1 minute)

---

## Deployment Checklist

### Server Setup
- [ ] Install Clojure on server
- [ ] Clone voice-code repository
- [ ] Configure port in config.edn
- [ ] Install Tailscale: `curl -fsSL https://tailscale.com/install.sh | sh`
- [ ] Start Tailscale: `sudo tailscale up`
- [ ] Note Tailscale IP: `tailscale ip`
- [ ] Start server: `clojure -M -m voice-code.server`
- [ ] Verify server listening on port

### iPhone Setup
- [ ] Install Xcode and build app
- [ ] Install on iPhone via Xcode or TestFlight
- [ ] Install Tailscale app from App Store
- [ ] Login to Tailscale (same account as server)
- [ ] Open voice-code app
- [ ] Go to Settings (gear icon)
- [ ] Enter server Tailscale IP (e.g., 100.64.0.1)
- [ ] Test connection
- [ ] Create first session with working directory

### Verification
- [ ] Send test prompt via voice: "What files are in this directory?"
- [ ] Verify Claude response is spoken aloud
- [ ] Check message appears in UI
- [ ] Switch to text input mode
- [ ] Send test prompt via text: "List all *.md files"
- [ ] Create second session with different directory
- [ ] Verify session switching works

---

## Known Limitations (v0.1.0)

1. **No Thread Organization**: Single conversation per session (add in v2)
2. **No Voice Replay**: Auto-play only (add replay buttons in v2)
3. **No Streaming**: Blocking invocation with timeout (add streaming in v2)
4. **In-Memory Backend State**: Sessions lost on server restart (add persistence in v2)
5. **No Rate Limiting**: Rely on Tailscale security (add in v2)
6. **Basic Error Handling**: Shows error messages but limited recovery options
7. **UserDefaults Storage**: Won't scale to very large conversation histories (migrate to Core Data in v2)

---

## Future Enhancements (v2+)

### High Priority
- [ ] Thread organization within sessions
- [ ] Voice replay per message
- [ ] Streaming responses from Claude
- [ ] Backend session persistence (EDN file)
- [ ] Better error recovery (retry failed requests)

### Medium Priority
- [ ] Rate limiting and request throttling
- [ ] Core Data migration for large conversations
- [ ] Battery profiling and optimization
- [ ] Voice activity detection (auto-stop recording)
- [ ] Working directory picker/browser

### Low Priority
- [ ] Authentication beyond Tailscale
- [ ] Multi-user support
- [ ] WebSocket compression
- [ ] Dark mode UI improvements
- [ ] iPad layout optimization
- [ ] Siri Shortcuts integration

---

## Success Criteria for MVP

The MVP is successful if a developer can:

1. ✅ **Speak a coding question** and hear Claude's response
2. ✅ **Type/paste code snippets** when needed
3. ✅ **Switch between projects** via sessions
4. ✅ **Resume conversations** in the same session
5. ✅ **Access remotely** via Tailscale from anywhere
6. ✅ **Recover from errors** (network drops, timeouts)
7. ✅ **Read conversation history** in the app

If these work reliably, the MVP demonstrates the core value proposition and validates the architecture for future enhancements.
