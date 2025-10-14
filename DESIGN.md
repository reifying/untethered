# Voice-Controlled Claude Code System Design

A system that enables voice-based interaction with Claude Code running on a laptop/server, accessible via iPhone using speech input/output.

## Overview

This design document outlines a complete voice-controlled coding system that mirrors Claude Code's functionality but accessible via iPhone voice interface. The system features:

- **Voice Input & Output**: Push-to-talk voice input with real-time transcription and text-to-speech responses
- **Voice Replay**: Replay any Claude response by voice with a single button tap
- **Readable Interface**: Full text display with selectable/copyable content for all messages
- **Session Management**: Multiple sessions tied to different working directories, matching Claude Code's session model
- **Thread Organization**: Nested threads within sessions for organizing different conversations, just like Claude Code
- **Backend**: Clojure server running on laptop/server, invoking Claude Code CLI programmatically
- **Enhanced REPL**: Integration with clojure-mcp for REPL-driven Clojure development
- **Remote Access**: Tailscale VPN for secure access from anywhere

## Table of Contents
- [System Architecture](#system-architecture)
- [Tech Stack Recommendations](#tech-stack-recommendations)
- [Data Flow](#data-flow)
- [Backend Implementation (Clojure)](#backend-implementation-clojure)
- [iPhone App Implementation](#iphone-app-implementation)
- [Clojure-MCP Integration](#clojure-mcp-integration)
- [Deployment Strategy](#deployment-strategy)
- [Security Considerations](#security-considerations)

---

## System Architecture

```
┌─────────────────┐
│   iPhone App    │
│  (Swift/SwiftUI)│
│                 │
│  ┌───────────┐  │
│  │  Speech   │  │ (Apple Speech Framework)
│  │  Input    │  │
│  └─────┬─────┘  │
│        │        │
│        ▼        │
│  ┌───────────┐  │
│  │ WebSocket │  │ (URLSessionWebSocketTask)
│  │  Client   │  │
│  └─────┬─────┘  │
│        │        │
│        ▼        │
│  ┌───────────┐  │
│  │   Text    │  │ (AVSpeechSynthesizer)
│  │  Output   │  │
│  └───────────┘  │
└────────┬────────┘
         │ Tailscale VPN
         │ (encrypted tunnel)
         │
         ▼
┌─────────────────────────────┐
│   Clojure Server (Backend)  │
│                             │
│  ┌──────────────────────┐   │
│  │  WebSocket Server    │   │ (http-kit + gniazdo)
│  │  - Bidirectional     │   │
│  │  - Session mgmt      │   │
│  └──────────┬───────────┘   │
│             │               │
│             ▼               │
│  ┌──────────────────────┐   │
│  │  Claude Code Invoker │   │ (clojure.java.shell)
│  │  - CLI subprocess    │   │
│  │  - JSON parsing      │   │
│  │  - Session resume    │   │
│  └──────────┬───────────┘   │
│             │               │
│  ┌──────────▼───────────┐   │
│  │   nREPL Server       │   │ (optional)
│  │   + clojure-mcp      │   │
│  │   - REPL tools       │   │
│  │   - Code editing     │   │
│  └──────────────────────┘   │
└──────────┬──────────────────┘
           │
           ▼
    ┌──────────────┐
    │  Claude Code │
    │     CLI      │
    │              │
    │  (running in │
    │   workspace) │
    └──────────────┘
```

---

## Tech Stack Recommendations

### iPhone App (Swift)

| Component | Technology | Justification |
|-----------|-----------|---------------|
| **Language** | Swift + SwiftUI | Native performance, best iOS integration |
| **Speech-to-Text** | Apple Speech Framework | On-device, privacy-focused, low latency, free |
| **Text-to-Speech** | AVSpeechSynthesizer | On-device, works offline, no API costs, acceptable quality |
| **Networking** | URLSessionWebSocketTask | Native iOS 13+, reliable, no dependencies |
| **Alternative STT** | WhisperKit (optional) | Better accuracy, still on-device, ~1GB RAM |
| **Alternative TTS** | Smallest.ai Lightning API | <100ms latency for premium experience |

**Battery Considerations:**
- Apple Speech Framework: Most efficient (purpose-built by Apple)
- WhisperKit: Optimized for Apple Neural Engine but uses more battery
- Recommendation: Start with native, profile WhisperKit if accuracy issues

### Clojure Backend

Based on successful patterns from `claude-slack` project:

```clojure
;; deps.edn (adapted from claude-slack/deps.edn:1-49)
{:paths ["src" "resources"]
 :deps {org.clojure/clojure {:mvn/version "1.12.3"}
        org.clojure/core.async {:mvn/version "1.7.701"}
        org.clojure/tools.logging {:mvn/version "1.3.0"}

        ;; HTTP & WebSocket
        http-kit/http-kit {:mvn/version "2.8.1"}
        stylefruits/gniazdo {:mvn/version "1.2.2"}  ; WebSocket

        ;; JSON parsing
        metosin/jsonista {:mvn/version "0.3.13"}
        cheshire/cheshire {:mvn/version "6.1.0"}

        ;; Utilities
        com.taoensso/timbre {:mvn/version "6.6.1"}
        environ/environ {:mvn/version "1.2.0"}}

 :aliases {;; nREPL for clojure-mcp
           :nrepl {:extra-paths ["test"]
                   :extra-deps {nrepl/nrepl {:mvn/version "1.3.1"}}
                   :jvm-opts ["-Djdk.attach.allowAttachSelf"]
                   :main-opts ["-m" "nrepl.cmdline" "--port" "7888"]}

           ;; clojure-mcp integration
           :mcp {:extra-deps {org.slf4j/slf4j-nop {:mvn/version "2.0.16"}
                              com.bhauman/clojure-mcp
                              {:git/url "https://github.com/bhauman/clojure-mcp.git"
                               :git/tag "v0.1.11-alpha"
                               :git/sha "7739dba"}}
                 :exec-fn clojure-mcp.main/start-mcp-server
                 :exec-args {:port 7888}}}}
```

**Key Libraries:**
- **http-kit**: High-performance async HTTP server
- **gniazdo**: WebSocket library (used in claude-slack for Slack Socket Mode)
- **core.async**: Concurrency primitives for streaming
- **cheshire/jsonista**: Fast JSON parsing for Claude CLI output

---

## Data Flow

### Session & Thread Hierarchy

The app organizes conversations like Claude Code:

```
Sessions (tied to working directories)
│
├─ Session 1: /Users/user/project-a
│  ├─ Thread 1: "Fix authentication bug"
│  │  ├─ Message 1 (user): "How do I fix the auth error?"
│  │  ├─ Message 2 (assistant): "Let me check the code..."
│  │  └─ Message 3 (user): "Can you show me?"
│  │
│  └─ Thread 2: "Add new feature"
│     ├─ Message 1 (user): "I need to add pagination"
│     └─ Message 2 (assistant): "Here's how..."
│
└─ Session 2: /Users/user/project-b
   └─ Thread 1: "Review code"
      ├─ Message 1 (user): "Review this function"
      └─ Message 2 (assistant): "The function looks good..."
```

**Benefits:**
- **Sessions**: Isolate work by project/directory
- **Threads**: Multiple conversations within a project
- **Persistence**: All saved to UserDefaults, resume anytime
- **Claude Session IDs**: Backend tracks Claude Code session IDs for continuity

### Voice Input → Claude Code

```
User speaks
  ↓
Apple Speech Framework (real-time transcription)
  ↓
Text accumulation (wait for pause or manual trigger)
  ↓
WebSocket message: {"type": "prompt", "text": "...", "session_id": "..."}
  ↓
Clojure server receives message
  ↓
invoke-claude function (subprocess)
  ↓
Claude Code CLI --output-format json --resume <session-id>
  ↓
Parse JSON response
  ↓
WebSocket message: {"type": "response", "text": "...", "session_id": "..."}
  ↓
iPhone receives response
  ↓
AVSpeechSynthesizer speaks text
  ↓
User hears response
```

### Session Management

- **Session persistence**: Use Claude Code's `--resume` flag
- **Working directory**: Set via `--cwd` or `:dir` in shell/sh
- **State tracking**: Store active sessions in Clojure atom (like claude-slack)

---

## Backend Implementation (Clojure)

### 1. Claude Code CLI Invocation

**Reference**: `claude-slack/src/claude_slack_bot/claude/client.clj:1-98`

```clojure
(ns voice-code.claude.client
  (:require [clojure.java.shell :as shell]
            [cheshire.core :as json]
            [clojure.tools.logging :as log]))

(def claude-cli-path
  "Path to Claude Code CLI binary"
  "<home-dir>/.claude/local/claude")

(defn invoke-claude
  "Invoke Claude CLI and return parsed JSON response.

   Based on claude-slack/src/claude_slack_bot/claude/client.clj:9-97

   Options:
   - :session-id - Resume existing session
   - :model - Model name (default 'sonnet')
   - :working-directory - Directory to run CLI from

   Returns map with:
   - :success - boolean
   - :result - response text (if success)
   - :session-id - session ID for future resumption
   - :usage - token usage stats
   - :cost - API cost in USD
   - :error - error details (if failure)"
  [prompt & {:keys [session-id model working-directory]
             :or {model "sonnet"}}]
  (let [args (cond-> ["--dangerously-skip-permissions"
                      "--output-format" "json"
                      "--model" model]
               session-id (concat ["--resume" session-id])
               true (concat [prompt]))

        shell-opts (if working-directory
                     [:dir working-directory]
                     [])

        _ (log/info "Invoking Claude CLI"
                    {:args args
                     :session-id session-id
                     :working-directory working-directory})

        result (apply shell/sh claude-cli-path (concat args shell-opts))]

    (if (zero? (:exit result))
      (try
        ;; Claude CLI returns an array of JSON objects
        (let [response-array (json/parse-string (:out result) true)
              ;; Find the result object (type = "result")
              result-obj (first (filter #(= "result" (:type %)) response-array))

              _ (when-not result-obj
                  (log/error "No result object found in CLI response"
                             {:response-types (map :type response-array)}))

              success (and result-obj
                           (not (:is_error result-obj)))
              result-text (:result result-obj)
              new-session-id (:session_id result-obj)]

          (if success
            {:success true
             :result result-text
             :session-id new-session-id
             :usage (:usage result-obj)
             :cost (:total_cost_usd result-obj)}
            {:success false
             :error (str "Claude CLI returned error: " result-text)
             :cli-response result-obj}))

        (catch Exception e
          (log/error e "Failed to parse Claude CLI response")
          {:success false
           :error (str "Failed to parse response: " (ex-message e))
           :raw-output (:out result)}))

      (do
        (log/error "Claude CLI failed" {:exit (:exit result)
                                        :stderr (:err result)})
        {:success false
         :error (str "CLI exited with code " (:exit result))
         :stderr (:err result)
         :exit-code (:exit result)}))))
```

### 2. WebSocket Server

**Reference**: `claude-slack/src/claude_slack_bot/slack/socket_mode.clj:1-126`

```clojure
(ns voice-code.websocket.server
  (:require [org.httpkit.server :as http]
            [cheshire.core :as json]
            [clojure.core.async :as async]
            [clojure.tools.logging :as log]
            [voice-code.claude.client :as claude]))

(defn handle-websocket-message
  "Process incoming WebSocket message from iPhone"
  [session-state msg]
  (try
    (let [data (json/parse-string msg true)]
      (case (:type data)
        "prompt"
        (let [prompt (:text data)
              session-id (:session_id @session-state)
              working-dir (:working_directory @session-state)

              ;; Invoke Claude Code CLI (like claude-slack does)
              response (claude/invoke-claude
                         prompt
                         :session-id session-id
                         :working-directory working-dir)]

          ;; Update session state with new session ID
          (when (:success response)
            (swap! session-state assoc :session_id (:session-id response)))

          ;; Return response to iPhone
          (json/generate-string
            {:type "response"
             :success (:success response)
             :text (:result response)
             :session_id (:session-id response)
             :usage (:usage response)
             :error (:error response)}))

        "set-directory"
        (do
          (swap! session-state assoc :working_directory (:path data))
          (json/generate-string {:type "ack" :message "Working directory set"}))

        "ping"
        (json/generate-string {:type "pong"})

        (do
          (log/warn "Unknown message type" {:type (:type data)})
          (json/generate-string {:type "error" :message "Unknown message type"}))))

    (catch Exception e
      (log/error e "Error handling WebSocket message")
      (json/generate-string {:type "error" :message (ex-message e)}))))

(defn websocket-handler
  "WebSocket handler for iPhone connections"
  [request]
  (http/with-channel request channel
    (if (http/websocket? channel)
      (let [session-state (atom {:session_id nil
                                 :working_directory nil
                                 :connected_at (System/currentTimeMillis)})]
        (log/info "WebSocket connected" {:channel channel})

        (http/on-receive channel
          (fn [msg]
            (let [response (handle-websocket-message session-state msg)]
              (http/send! channel response))))

        (http/on-close channel
          (fn [status]
            (log/info "WebSocket closed" {:status status :session @session-state})))

        ;; Send initial connection acknowledgment
        (http/send! channel
          (json/generate-string {:type "connected" :message "Ready for voice input"})))

      ;; Not a WebSocket request
      (http/send! channel {:status 400 :body "WebSocket required"}))))

(defn start-server
  "Start HTTP server with WebSocket support"
  [port]
  (http/run-server websocket-handler {:port port})
  (log/info "WebSocket server started" {:port port}))
```

### 3. Session State Management

**Reference**: `claude-slack/src/claude_slack_bot/state.clj`

```clojure
(ns voice-code.state
  (:require [clojure.tools.logging :as log]))

(defonce active-sessions
  "Map of WebSocket channel -> session state"
  (atom {}))

(defn create-session!
  [channel]
  (let [session {:id (str (java.util.UUID/randomUUID))
                 :claude-session-id nil
                 :working-directory nil
                 :created-at (System/currentTimeMillis)
                 :last-activity (System/currentTimeMillis)}]
    (swap! active-sessions assoc channel session)
    (log/info "Session created" {:session-id (:id session)})
    session))

(defn update-session!
  [channel updates]
  (swap! active-sessions update channel merge updates)
  (swap! active-sessions assoc-in [channel :last-activity] (System/currentTimeMillis)))

(defn remove-session!
  [channel]
  (let [session (get @active-sessions channel)]
    (swap! active-sessions dissoc channel)
    (log/info "Session removed" {:session-id (:id session)})))

(defn get-session
  [channel]
  (get @active-sessions channel))

(defn cleanup-stale-sessions!
  "Remove sessions inactive for more than timeout-ms"
  [timeout-ms]
  (let [now (System/currentTimeMillis)
        stale-channels (filter
                         (fn [[_ session]]
                           (> (- now (:last-activity session)) timeout-ms))
                         @active-sessions)]
    (doseq [[channel _] stale-channels]
      (remove-session! channel))
    (count stale-channels)))

;; Start cleanup background task
(defn start-session-cleanup!
  []
  (future
    (while true
      (Thread/sleep 60000) ; Check every minute
      (let [removed (cleanup-stale-sessions! (* 30 60 1000))] ; 30 min timeout
        (when (pos? removed)
          (log/info "Cleaned up stale sessions" {:count removed}))))))
```

---

## iPhone App Implementation

### Key Features

The iPhone app provides a rich voice coding experience with:

1. **Voice Replay**: Every Claude response has a replay button (speaker icon) to hear it again on demand
   - Useful for reviewing complex explanations
   - Works even if auto-play was disabled
   - Independent of the original voice playback

2. **Readable Text**: All messages are displayed as readable text with text selection enabled
   - Copy code snippets directly from responses
   - Search and reference previous conversations
   - Visual context while listening

3. **Session Management**: Create multiple sessions with different working directories
   - Switch between projects instantly
   - Each session maintains its own Claude Code session ID
   - View all sessions with creation time and activity

4. **Thread Organization**: Multiple conversation threads per session, like Claude Code
   - Start new threads for different topics within a project
   - Auto-generated thread titles from first message
   - Navigate between threads without losing context

5. **Auto-play Toggle**: Choose whether Claude responses are automatically spoken
   - Toggle in top bar for quick access
   - Visual indicator (speaker icon) shows current state
   - Manual replay always available regardless of setting

6. **Persistent Storage**: Sessions and threads saved to UserDefaults
   - App state preserved across restarts
   - Full conversation history available
   - Resume any session/thread instantly

7. **Push-to-Talk**: Simple mic button for voice input
   - Press to start recording, release to send
   - Visual feedback (red indicator) while recording
   - Real-time transcription display

8. **Real-time Transcription**: See what you're saying as you speak
   - Helps verify accuracy before sending
   - Shows in bottom bar while recording
   - Editable if needed (future enhancement)

9. **Text Input Option**: Type prompts instead of speaking when needed
   - Switch between voice and text input
   - Essential for pasting code, URLs, or complex terms
   - Useful in quiet environments or when speech recognition struggles

10. **Server Configuration**: Easy setup for connecting to your server
    - Settings view to enter server URL and port
    - Auto-discover via Tailscale (optional enhancement)
    - Test connection button
    - Saved to UserDefaults for persistence

### 1. App Settings Manager

```swift
import Foundation

class AppSettings: ObservableObject {
    @Published var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: "serverURL")
        }
    }

    @Published var serverPort: String {
        didSet {
            UserDefaults.standard.set(serverPort, forKey: "serverPort")
        }
    }

    var fullServerURL: String {
        let port = serverPort.isEmpty ? "8080" : serverPort
        let baseURL = serverURL.hasPrefix("ws://") || serverURL.hasPrefix("wss://")
            ? serverURL
            : "ws://\(serverURL)"
        return "\(baseURL):\(port)/ws"
    }

    init() {
        self.serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "100.64.0.1"
        self.serverPort = UserDefaults.standard.string(forKey: "serverPort") ?? "8080"
    }

    func testConnection(completion: @escaping (Bool, String?) -> Void) {
        let testClient = VoiceCodeClient(serverURL: fullServerURL)
        testClient.connect()

        // Wait a bit and check connection status
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if testClient.isConnected {
                testClient.disconnect()
                completion(true, "Connected successfully")
            } else {
                completion(false, "Failed to connect")
            }
        }
    }
}
```

### 2. WebSocket Client

```swift
import Foundation

class VoiceCodeClient: ObservableObject {
    @Published var isConnected = false
    @Published var currentResponse = ""
    @Published var sessionId: String?

    private var webSocketTask: URLSessionWebSocketTask?
    private let serverURL: URL

    init(serverURL: String) {
        self.serverURL = URL(string: serverURL)!
    }

    func connect() {
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: serverURL)
        webSocketTask?.resume()

        isConnected = true
        receiveMessage()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        isConnected = false
    }

    func sendPrompt(_ text: String, sessionId: String? = nil) {
        var message: [String: Any] = [
            "type": "prompt",
            "text": text
        ]

        if let sessionId = sessionId {
            message["session_id"] = sessionId
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(wsMessage) { error in
            if let error = error {
                print("WebSocket send error: \(error)")
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                @unknown default:
                    break
                }

                // Continue receiving
                self?.receiveMessage()

            case .failure(let error):
                print("WebSocket receive error: \(error)")
                self?.isConnected = false
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        DispatchQueue.main.async {
            if let type = json["type"] as? String {
                switch type {
                case "response":
                    self.currentResponse = json["text"] as? String ?? ""
                    self.sessionId = json["session_id"] as? String
                case "connected":
                    print("Connected to server: \(json["message"] ?? "")")
                case "error":
                    print("Server error: \(json["message"] ?? "")")
                default:
                    break
                }
            }
        }
    }
}
```

### 2. Speech Recognition Integration

```swift
import Speech

class VoiceInputManager: ObservableObject {
    @Published var transcribedText = ""
    @Published var isRecording = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    print("Speech recognition authorized")
                default:
                    print("Speech recognition not authorized")
                }
            }
        }
    }

    func startRecording() throws {
        // Cancel previous task if exists
        recognitionTask?.cancel()
        recognitionTask = nil

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "VoiceInput", code: 1)
        }

        recognitionRequest.shouldReportPartialResults = true

        // Configure audio input
        let inputNode = audioEngine.inputNode

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            if let result = result {
                DispatchQueue.main.async {
                    self?.transcribedText = result.bestTranscription.formattedString
                }
            }

            if error != nil || result?.isFinal == true {
                self?.audioEngine.stop()
                inputNode.removeTap(onBus: 0)

                self?.recognitionRequest = nil
                self?.recognitionTask = nil

                DispatchQueue.main.async {
                    self?.isRecording = false
                }
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        DispatchQueue.main.async {
            self.isRecording = true
        }
    }

    func stopRecording() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        isRecording = false
    }
}
```

### 3. Text-to-Speech Integration

```swift
import AVFoundation

class VoiceOutputManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)

        // Configure voice parameters
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5 // Adjust for comfortable listening (0.0 - 1.0)
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // Delegate methods
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = true
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }
}
```

### 4. Session & Thread Management

```swift
import Foundation

// Message model for conversation history
struct Message: Identifiable, Codable {
    let id: UUID
    let role: String // "user" or "assistant"
    let content: String
    let timestamp: Date
    var isSpoken: Bool = false

    init(role: String, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

// Thread model (like Claude Code threads)
struct Thread: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [Message]
    let createdAt: Date
    var lastActivity: Date

    init(title: String = "New Thread") {
        self.id = UUID()
        self.title = title
        self.messages = []
        self.createdAt = Date()
        self.lastActivity = Date()
    }

    mutating func addMessage(_ message: Message) {
        messages.append(message)
        lastActivity = Date()

        // Auto-generate title from first message
        if messages.count == 1 && title == "New Thread" {
            let preview = String(message.content.prefix(50))
            title = preview + (message.content.count > 50 ? "..." : "")
        }
    }
}

// Session model (like Claude Code sessions)
class Session: ObservableObject, Identifiable, Codable {
    let id: UUID
    let claudeSessionId: String?
    var workingDirectory: String
    var threads: [Thread]
    var currentThreadId: UUID?
    let createdAt: Date
    var lastActivity: Date

    enum CodingKeys: String, CodingKey {
        case id, claudeSessionId, workingDirectory, threads, currentThreadId, createdAt, lastActivity
    }

    init(workingDirectory: String = "", claudeSessionId: String? = nil) {
        self.id = UUID()
        self.claudeSessionId = claudeSessionId
        self.workingDirectory = workingDirectory
        self.threads = []
        self.currentThreadId = nil
        self.createdAt = Date()
        self.lastActivity = Date()
    }

    func createThread(title: String = "New Thread") -> Thread {
        let thread = Thread(title: title)
        threads.append(thread)
        currentThreadId = thread.id
        lastActivity = Date()
        return thread
    }

    func getCurrentThread() -> Thread? {
        guard let currentThreadId = currentThreadId else { return nil }
        return threads.first { $0.id == currentThreadId }
    }

    func addMessageToCurrentThread(_ message: Message) {
        guard let index = threads.firstIndex(where: { $0.id == currentThreadId }) else {
            return
        }
        threads[index].addMessage(message)
        lastActivity = Date()
    }

    // Codable conformance
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        claudeSessionId = try container.decodeIfPresent(String.self, forKey: .claudeSessionId)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        threads = try container.decode([Thread].self, forKey: .threads)
        currentThreadId = try container.decodeIfPresent(UUID.self, forKey: .currentThreadId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastActivity = try container.decode(Date.self, forKey: .lastActivity)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(claudeSessionId, forKey: .claudeSessionId)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(threads, forKey: .threads)
        try container.encodeIfPresent(currentThreadId, forKey: .currentThreadId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastActivity, forKey: .lastActivity)
    }
}

// Session manager with persistence
class SessionManager: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var currentSessionId: UUID?

    private let storageKey = "voice_code_sessions"

    init() {
        loadSessions()
    }

    func createSession(workingDirectory: String = "") -> Session {
        let session = Session(workingDirectory: workingDirectory)
        sessions.append(session)
        currentSessionId = session.id
        saveSessions()
        return session
    }

    func getCurrentSession() -> Session? {
        guard let currentSessionId = currentSessionId else { return nil }
        return sessions.first { $0.id == currentSessionId }
    }

    func saveSessions() {
        if let encoded = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    func loadSessions() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = decoded
        }
    }

    func deleteSession(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        if currentSessionId == session.id {
            currentSessionId = sessions.first?.id
        }
        saveSessions()
    }
}
```

### 5. Main SwiftUI View with Sessions & Threads

```swift
import SwiftUI

struct ContentView: View {
    @StateObject private var voiceInput = VoiceInputManager()
    @StateObject private var voiceOutput = VoiceOutputManager()
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var appSettings = AppSettings()
    @StateObject private var client: VoiceCodeClient

    @State private var showingSessions = false
    @State private var showingThreads = false
    @State private var showingSettings = false
    @State private var autoPlayVoice = true
    @State private var inputMode: InputMode = .voice
    @State private var textInput = ""

    enum InputMode {
        case voice
        case text
    }

    init() {
        let settings = AppSettings()
        _appSettings = StateObject(wrappedValue: settings)
        _client = StateObject(wrappedValue: VoiceCodeClient(serverURL: settings.serverURL))
    }

    var currentSession: Session? {
        sessionManager.getCurrentSession()
    }

    var currentThread: Thread? {
        currentSession?.getCurrentThread()
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Top bar with connection status and controls
                HStack {
                    // Connection indicator
                    HStack(spacing: 6) {
                        Circle()
                            .fill(client.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(client.isConnected ? "Connected" : "Disconnected")
                            .font(.caption)
                    }

                    Spacer()

                    // Auto-play voice toggle
                    Toggle("", isOn: $autoPlayVoice)
                        .labelsHidden()
                        .frame(width: 50)
                    Image(systemName: autoPlayVoice ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.caption)

                    // Sessions button
                    Button(action: { showingSessions.toggle() }) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 18))
                    }

                    // Threads button
                    Button(action: { showingThreads.toggle() }) {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 18))
                    }

                    // Settings button
                    Button(action: { showingSettings.toggle() }) {
                        Image(systemName: "gear")
                            .font(.system(size: 18))
                    }
                }
                .padding()
                .background(Color(.systemGray6))

                // Current session info
                if let session = currentSession {
                    HStack {
                        Text(session.workingDirectory.isEmpty ? "No directory set" : session.workingDirectory)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        Spacer()

                        if let thread = currentThread {
                            Text("\(thread.messages.count) messages")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6).opacity(0.5))
                }

                Divider()

                // Messages display
                ScrollViewReader { proxy in
                    ScrollView {
                        if let thread = currentThread {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(thread.messages) { message in
                                    MessageView(
                                        message: message,
                                        onReplay: {
                                            voiceOutput.speak(message.content)
                                        }
                                    )
                                    .id(message.id)
                                }
                            }
                            .padding()
                            .onChange(of: thread.messages.count) { _ in
                                if let lastMessage = thread.messages.last {
                                    withAnimation {
                                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                    }
                                }
                            }
                        } else {
                            VStack(spacing: 20) {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 60))
                                    .foregroundColor(.gray)
                                Text("No active thread")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                Button("Start New Thread") {
                                    startNewThread()
                                }
                                .buttonStyle(.bordered)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                        }
                    }
                }

                Divider()

                // Input mode selector
                Picker("Input Mode", selection: $inputMode) {
                    Text("Voice").tag(InputMode.voice)
                    Text("Text").tag(InputMode.text)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                .padding(.top, 8)

                // Text input (when in text mode)
                if inputMode == .text {
                    HStack {
                        TextField("Type your message...", text: $textInput, axis: .vertical)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .lineLimit(3...6)

                        Button(action: sendTextMessage) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(textInput.isEmpty ? .gray : .blue)
                        }
                        .disabled(textInput.isEmpty)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                // Voice input indicator (when in voice mode)
                if inputMode == .voice && voiceInput.isRecording {
                    HStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text(voiceInput.transcribedText.isEmpty ? "Listening..." : voiceInput.transcribedText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                }

                // Push-to-talk button (only in voice mode)
                if inputMode == .voice {
                    Button(action: handlePushToTalk) {
                        VStack {
                            Image(systemName: voiceInput.isRecording ? "mic.fill" : "mic")
                                .font(.system(size: 36))
                                .foregroundColor(.white)
                        }
                        .frame(width: 70, height: 70)
                        .background(voiceInput.isRecording ? Color.red : Color.blue)
                        .clipShape(Circle())
                        .shadow(radius: 4)
                    }
                    .padding(.vertical, 20)
                }
            }
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showingSessions) {
            SessionsView(sessionManager: sessionManager)
        }
        .sheet(isPresented: $showingThreads) {
            if let session = currentSession {
                ThreadsView(session: session)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(settings: appSettings, onServerChange: { newURL in
                // Reconnect with new URL
                client.disconnect()
                client = VoiceCodeClient(serverURL: newURL)
                client.connect()
            })
        }
        .onAppear {
            voiceInput.requestPermissions()
            client.connect()

            // Create initial session if needed
            if sessionManager.sessions.isEmpty {
                let session = sessionManager.createSession()
                session.createThread()
            } else if sessionManager.currentSessionId == nil {
                sessionManager.currentSessionId = sessionManager.sessions.first?.id
            }

            // Ensure current session has a thread
            if let session = currentSession, session.threads.isEmpty {
                session.createThread()
            }
        }
        .onChange(of: client.currentResponse) { newResponse in
            if !newResponse.isEmpty {
                // Add assistant message to thread
                let message = Message(role: "assistant", content: newResponse)
                currentSession?.addMessageToCurrentThread(message)
                sessionManager.saveSessions()

                // Auto-play voice if enabled
                if autoPlayVoice {
                    voiceOutput.speak(newResponse)
                }
            }
        }
    }

    func handlePushToTalk() {
        if voiceInput.isRecording {
            voiceInput.stopRecording()

            // Send to Claude
            if !voiceInput.transcribedText.isEmpty {
                // Ensure thread exists
                if currentThread == nil {
                    currentSession?.createThread()
                }

                // Add user message to thread
                let userMessage = Message(role: "user", content: voiceInput.transcribedText)
                currentSession?.addMessageToCurrentThread(userMessage)
                sessionManager.saveSessions()

                // Send prompt
                client.sendPrompt(
                    voiceInput.transcribedText,
                    sessionId: currentSession?.claudeSessionId
                )

                // Clear transcription
                voiceInput.transcribedText = ""
            }
        } else {
            try? voiceInput.startRecording()
        }
    }

    func startNewThread() {
        guard let session = currentSession else { return }
        session.createThread()
        sessionManager.saveSessions()
    }

    func sendTextMessage() {
        guard !textInput.isEmpty else { return }

        // Ensure thread exists
        if currentThread == nil {
            currentSession?.createThread()
        }

        // Add user message to thread
        let userMessage = Message(role: "user", content: textInput)
        currentSession?.addMessageToCurrentThread(userMessage)
        sessionManager.saveSessions()

        // Send prompt
        client.sendPrompt(
            textInput,
            sessionId: currentSession?.claudeSessionId
        )

        // Clear text input
        textInput = ""
    }
}

// Individual message view with replay button
struct MessageView: View {
    let message: Message
    let onReplay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Role icon
            Image(systemName: message.role == "user" ? "person.circle.fill" : "cpu")
                .font(.system(size: 24))
                .foregroundColor(message.role == "user" ? .blue : .green)

            VStack(alignment: .leading, spacing: 6) {
                // Role label and timestamp
                HStack {
                    Text(message.role == "user" ? "You" : "Claude")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Spacer()

                    // Replay button (for assistant messages)
                    if message.role == "assistant" {
                        Button(action: onReplay) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                // Message content (readable text)
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .background(
            message.role == "user"
                ? Color.blue.opacity(0.1)
                : Color.green.opacity(0.1)
        )
        .cornerRadius(12)
    }
}

// Sessions list view
struct SessionsView: View {
    @ObservedObject var sessionManager: SessionManager
    @Environment(\.dismiss) var dismiss
    @State private var showingNewSession = false
    @State private var newSessionDirectory = ""

    var body: some View {
        NavigationView {
            List {
                ForEach(sessionManager.sessions) { session in
                    Button(action: {
                        sessionManager.currentSessionId = session.id
                        dismiss()
                    }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.workingDirectory.isEmpty ? "No directory" : session.workingDirectory)
                                .font(.headline)
                            HStack {
                                Text("\(session.threads.count) threads")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(session.lastActivity, style: .relative)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { indexSet in
                    indexSet.forEach { index in
                        sessionManager.deleteSession(sessionManager.sessions[index])
                    }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingNewSession.toggle() }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewSession) {
                NavigationView {
                    Form {
                        TextField("Working Directory", text: $newSessionDirectory)
                    }
                    .navigationTitle("New Session")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Cancel") {
                                showingNewSession = false
                                newSessionDirectory = ""
                            }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Create") {
                                let _ = sessionManager.createSession(workingDirectory: newSessionDirectory)
                                showingNewSession = false
                                newSessionDirectory = ""
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }
}

// Threads list view
struct ThreadsView: View {
    @ObservedObject var session: Session
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(session.threads) { thread in
                    Button(action: {
                        session.currentThreadId = thread.id
                        dismiss()
                    }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(thread.title)
                                .font(.headline)
                                .lineLimit(1)
                            HStack {
                                Text("\(thread.messages.count) messages")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(thread.lastActivity, style: .relative)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Threads")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        session.createThread()
                        dismiss()
                    }) {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}
```

---

## Clojure-MCP Integration

### Setup

**1. Add nREPL alias to `deps.edn`** (from clojure-mcp docs):

```clojure
:aliases {
  :nrepl {:extra-paths ["test"]
          :extra-deps {nrepl/nrepl {:mvn/version "1.3.1"}}
          :jvm-opts ["-Djdk.attach.allowAttachSelf"]
          :main-opts ["-m" "nrepl.cmdline" "--port" "7888"]}

  :mcp {:extra-deps {org.slf4j/slf4j-nop {:mvn/version "2.0.16"}
                     com.bhauman/clojure-mcp
                     {:git/url "https://github.com/bhauman/clojure-mcp.git"
                      :git/tag "v0.1.11-alpha"
                      :git/sha "7739dba"}}
        :exec-fn clojure-mcp.main/start-mcp-server
        :exec-args {:port 7888}}}
```

**2. Start nREPL server**:

```bash
clojure -M:nrepl
```

**3. Start clojure-mcp server** (separate terminal):

```bash
clojure -X:mcp :port 7888
```

### Integration with Voice Code System

**Why clojure-mcp?**

clojure-mcp allows Claude to:
- Evaluate code in a live REPL
- Perform structural editing (parinfer, clj-rewrite)
- Access REPL tools (namespace inspection, documentation)
- Debug and iterate on code interactively

**Architecture with clojure-mcp**:

```
Voice Input → Clojure Server → Claude Code CLI
                                    ↓
                            (if Clojure code task)
                                    ↓
                              clojure-mcp
                                    ↓
                              nREPL server
                                    ↓
                           Evaluate/Edit code
```

### Enhanced Claude Invocation with MCP Support

```clojure
(ns voice-code.claude.mcp
  (:require [voice-code.claude.client :as claude]
            [clojure.tools.logging :as log]))

(defn invoke-with-mcp-context
  "Invoke Claude with clojure-mcp available via MCP tools.

   Claude Code CLI can discover and use MCP servers configured in
   .claude/settings.json or global settings."
  [prompt & {:keys [session-id working-directory]
             :as opts}]
  (let [;; Ensure working directory has .claude/settings.json with MCP config
        mcp-config {:mcpServers
                    {:clojure-mcp
                     {:command "clojure"
                      :args ["-X:mcp" ":port" "7888"]}}}

        _ (log/info "Invoking Claude with MCP support"
                    {:working-directory working-directory
                     :session-id session-id})

        ;; Standard Claude invocation - Claude Code discovers MCP servers
        response (apply claude/invoke-claude prompt (apply concat opts))]

    response))
```

**Example .claude/settings.json with clojure-mcp**:

```json
{
  "mcpServers": {
    "clojure-mcp": {
      "command": "clojure",
      "args": ["-X:mcp", ":port", "7888"]
    }
  }
}
```

When Claude Code CLI runs in this directory, it will automatically connect to the clojure-mcp server and have access to REPL-driven development tools.

---

## Deployment Strategy

### Local Development

**1. Start nREPL** (terminal 1):
```bash
cd /path/to/project
clojure -M:nrepl
```

**2. Start clojure-mcp** (terminal 2):
```bash
clojure -X:mcp :port 7888
```

**3. Start Clojure WebSocket server** (terminal 3):
```bash
clojure -M -m voice-code.server
```

**4. Install Tailscale** (for remote access):
```bash
# macOS
brew install tailscale
sudo tailscale up

# Note your Tailscale IP (e.g., 100.x.x.x)
tailscale ip
```

**5. iPhone app configuration**:
```swift
let serverURL = "ws://100.x.x.x:8080/ws"  // Tailscale IP
```

### Production Deployment

**Option 1: Laptop/Desktop Server**
- Run Clojure server continuously (systemd/launchd)
- Tailscale always-on for remote access
- Wake-on-LAN for power management

**Option 2: Cloud Server** (VPS/EC2)
- Deploy Clojure server to cloud
- Tailscale subnet router for secure access
- Persistent storage for Claude sessions

### Tailscale Setup

**Why Tailscale?**
- Zero-config VPN (no port forwarding, no dynamic DNS)
- Works over cellular and WiFi seamlessly
- Encrypted WireGuard tunnel
- Free tier: 3 users, 100 devices
- iPhone app available

**Setup Steps**:

1. Install Tailscale on server:
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

2. Install Tailscale iOS app from App Store

3. Login with same account on both devices

4. Use Tailscale IP in iPhone app (e.g., `100.64.0.1`)

**Configuration Example**:

```bash
# Server: Check Tailscale IP
tailscale ip
# Output: 100.64.0.1

# iPhone app connects to: ws://100.64.0.1:8080/ws
```

---

## Security Considerations

### Authentication

**Option 1: Tailscale-only**
- Rely on Tailscale authentication (device-level trust)
- Simplest setup, suitable for personal use

**Option 2: Token-based**
```clojure
;; Server: Validate auth token on WebSocket connection
(defn websocket-handler [request]
  (let [token (get-in request [:headers "authorization"])]
    (if (valid-token? token)
      ;; Accept WebSocket
      (http/with-channel request channel ...)
      ;; Reject
      {:status 401 :body "Unauthorized"})))
```

```swift
// iPhone: Send auth token
var request = URLRequest(url: serverURL)
request.setValue("Bearer your-token", forHTTPHeaderField: "Authorization")
webSocketTask = session.webSocketTask(with: request)
```

### Data Privacy

- **On-device speech processing**: Apple Speech Framework doesn't send audio to external servers (for supported languages)
- **Encrypted transport**: Tailscale uses WireGuard (industry-standard encryption)
- **Local execution**: Claude Code runs on your machine, not in the cloud

### Rate Limiting

```clojure
(ns voice-code.middleware.rate-limit
  (:require [clojure.core.async :as async]))

(defonce rate-limiters (atom {}))

(defn rate-limit
  "Allow max `limit` requests per `window-ms` milliseconds"
  [channel limit window-ms]
  (let [limiter (get @rate-limiters channel
                     (atom {:count 0 :window-start (System/currentTimeMillis)}))]
    (swap! rate-limiters assoc channel limiter)

    (let [{:keys [count window-start]} @limiter
          now (System/currentTimeMillis)]
      (if (> (- now window-start) window-ms)
        ;; Reset window
        (do
          (reset! limiter {:count 1 :window-start now})
          true)
        ;; Check limit
        (if (< count limit)
          (do
            (swap! limiter update :count inc)
            true)
          false)))))
```

---

## Implementation Checklist

### Backend (Clojure)

- [ ] Set up project with deps.edn
- [ ] Implement `voice-code.claude.client/invoke-claude` (based on claude-slack)
- [ ] Implement WebSocket server with http-kit
- [ ] Add session state management
- [ ] Integrate clojure-mcp for REPL-driven development
- [ ] Add rate limiting and error handling
- [ ] Write tests

### iPhone App (Swift)

- [ ] Create SwiftUI project
- [ ] Implement WebSocket client
- [ ] Integrate Apple Speech Framework (STT)
- [ ] Integrate AVSpeechSynthesizer (TTS)
- [ ] Add push-to-talk UI
- [ ] Handle session management
- [ ] Add settings for server URL and working directory
- [ ] Test with Tailscale VPN

### Deployment

- [ ] Install Tailscale on server and iPhone
- [ ] Configure systemd/launchd for auto-start
- [ ] Set up .claude/settings.json with MCP config
- [ ] Test end-to-end voice workflow
- [ ] Monitor battery usage on iPhone
- [ ] Document setup and troubleshooting

---

## Alternative Architectures Considered

### 1. Direct Claude API (without Claude Code CLI)

**Pros:**
- More control over API parameters
- Streaming responses easier to implement
- No subprocess overhead

**Cons:**
- Loses Claude Code's session management
- No access to Claude Code's file tools
- Can't leverage .claude/settings.json config
- No MCP server integration

**Verdict:** Use Claude Code CLI for consistency with local development workflow.

### 2. REST API instead of WebSocket

**Pros:**
- Simpler implementation
- Standard HTTP tooling

**Cons:**
- Higher latency (request/response cycle)
- No server-push for streaming
- Less efficient for conversational back-and-forth

**Verdict:** WebSocket is better for real-time voice interaction.

### 3. Direct SSH from iPhone to run Claude CLI

**Pros:**
- No middleware server needed

**Cons:**
- SSH apps have iOS background limitations (3-10 min timeout)
- Complex authentication management
- Poor user experience

**Verdict:** WebSocket + Tailscale provides better UX.

---

## Performance Optimizations

### Latency Budget

Target: < 2 seconds end-to-end (voice in → voice out)

| Component | Target Latency | Optimization |
|-----------|----------------|--------------|
| Speech-to-Text | 200-500ms | On-device (Apple Speech) |
| Network (Tailscale) | 50-100ms | WireGuard is fast |
| WebSocket overhead | 10-20ms | http-kit is efficient |
| Claude Code CLI | 500-1500ms | Depends on query complexity |
| Text-to-Speech | 100-300ms | On-device (AVSpeechSynthesizer) |
| **Total** | **~860-2420ms** | Acceptable for voice UX |

### Optimization Strategies

1. **Parallel processing**: Start TTS immediately as Claude response arrives (streaming)
2. **Session caching**: Reuse Claude session IDs to avoid cold starts
3. **Connection pooling**: Keep WebSocket persistent (no reconnections)
4. **Audio buffering**: Pre-buffer TTS output for instant playback

### Battery Optimization (iPhone)

1. **Push-to-talk**: Avoid continuous listening
2. **On-device processing**: No cloud API calls for speech
3. **WebSocket keep-alive**: Minimize reconnection overhead
4. **Background limitations**: Gracefully handle app backgrounding

---

## Testing Strategy

### Unit Tests

```clojure
(ns voice-code.claude.client-test
  (:require [clojure.test :refer :all]
            [voice-code.claude.client :as claude]))

(deftest test-invoke-claude-success
  (testing "Successful Claude CLI invocation"
    (with-redefs [clojure.java.shell/sh
                  (fn [& args]
                    {:exit 0
                     :out "[{\"type\":\"result\",\"result\":\"Hello\",\"session_id\":\"123\"}]"})]
      (let [result (claude/invoke-claude "test prompt")]
        (is (:success result))
        (is (= "Hello" (:result result)))
        (is (= "123" (:session-id result)))))))

(deftest test-invoke-claude-error
  (testing "Claude CLI returns error"
    (with-redefs [clojure.java.shell/sh
                  (fn [& args]
                    {:exit 1
                     :err "Command not found"})]
      (let [result (claude/invoke-claude "test prompt")]
        (is (not (:success result)))
        (is (:error result))))))
```

### Integration Tests

```clojure
(ns voice-code.integration-test
  (:require [clojure.test :refer :all]
            [voice-code.websocket.server :as ws]
            [gniazdo.core :as gniazdo]
            [cheshire.core :as json]))

(deftest test-websocket-roundtrip
  (testing "WebSocket client can send prompt and receive response"
    (let [server-port 8081
          server (ws/start-server server-port)
          connected (promise)
          response (promise)

          client (gniazdo/connect
                   (str "ws://localhost:" server-port "/ws")
                   :on-connect (fn [_] (deliver connected true))
                   :on-receive (fn [msg]
                                 (let [data (json/parse-string msg true)]
                                   (when (= "response" (:type data))
                                     (deliver response data)))))]

      ;; Wait for connection
      (deref connected 5000 false)

      ;; Send prompt
      (gniazdo/send-msg client
        (json/generate-string {:type "prompt" :text "Hello"}))

      ;; Wait for response
      (let [resp (deref response 10000 nil)]
        (is (some? resp))
        (is (= "response" (:type resp))))

      (gniazdo/close client)
      (server))))
```

---

## References

### Existing Implementation

- **claude-slack project**: `<home-dir>/code/mono/active/claude-slack`
  - Claude CLI invocation: `src/claude_slack_bot/claude/client.clj:1-98`
  - WebSocket handling: `src/claude_slack_bot/slack/socket_mode.clj:1-126`
  - Session management: `src/claude_slack_bot/state.clj`

### Documentation

- [clojure-mcp GitHub](https://github.com/bhauman/clojure-mcp)
- [Claude Code Documentation](https://docs.claude.com/en/docs/claude-code)
- [Apple Speech Framework](https://developer.apple.com/documentation/speech)
- [Tailscale Documentation](https://tailscale.com/kb/)
- [http-kit Server](http://http-kit.github.io/server.html)

### Research Findings

- **Speech-to-Text**: Apple Speech Framework is most battery-efficient; WhisperKit for better accuracy
- **Text-to-Speech**: AVSpeechSynthesizer is native and free; cloud APIs (Smallest.ai, ElevenLabs) for premium quality
- **Networking**: WebSocket for bidirectional streaming; Tailscale VPN for secure remote access
- **Backend**: Clojure + http-kit + gniazdo proven in claude-slack; clojure-mcp adds REPL superpowers

---

## Next Steps

1. **Prototype Phase**: Build minimal WebSocket server + iPhone app with push-to-talk
2. **Integration Phase**: Connect to Claude Code CLI with session management
3. **Enhancement Phase**: Add clojure-mcp for advanced Clojure development
4. **Production Phase**: Deploy with Tailscale, add monitoring and error handling

**Estimated Timeline**: 2-3 weeks for functional prototype, 1-2 additional weeks for production-ready system.
