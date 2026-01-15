# Hooks-Based Session Tracking

## 1. Overview

### Problem Statement

The voice-code backend currently relies on watching Claude Code's internal `.jsonl` session files in `~/.claude/projects/`. This approach is tightly coupled to Claude Code's implementation details:

- JSONL file format and message schema
- Message type filtering (sidechain, summary, system)
- File path conventions
- Byte-level incremental parsing

**This coupling is fragile.** A recent Claude Code update broke the integration because the internal format changed. Any future Claude Code update could break voice-code again.

### Goals

1. **Decouple from internal formats** - Use only Claude Code's public API (CLI and hooks)
2. **Simplify the codebase** - Remove ~500 lines of file watching and JSONL parsing
3. **Own our data** - Store conversation history in our own format that we control
4. **Maintain core functionality** - iOS users can still send prompts, see responses, resume sessions

### Non-Goals

- **Full visibility into external sessions** - Sessions started directly via `claude` CLI will have limited visibility (existence only, not full history)
- **Streaming mid-turn updates** - Real-time tool use notifications during a prompt (defer to future work)
- **Backward compatibility for existing sessions** - Pre-migration sessions won't appear in iOS (users start fresh)

## 2. Background & Context

### Current State

The backend uses a file watcher (`replication.clj`) that:

1. Monitors `~/.claude/projects/**/*.jsonl` via Java NIO.2 WatchService
2. Parses Claude Code's JSONL format with incremental byte-position tracking
3. Filters internal message types (sidechain, warmup, summary, system)
4. Debounces rapid file changes (200ms)
5. Handles race conditions between file watcher and prompt handler
6. Extracts session metadata (name, working directory) by parsing file contents

This results in ~600 lines of complex code with tight coupling to Claude Code internals.

### Why Now

A Claude Code update changed the internal JSONL format, breaking the voice-code integration. This is the second time format changes have caused issues. The current architecture guarantees future breakage.

### Related Work

- @STANDARDS.md - WebSocket protocol documentation
- `backend/src/voice_code/replication.clj` - Current file watcher implementation
- `backend/src/voice_code/claude.clj` - CLI invocation (already uses public API correctly)

## 3. Detailed Design

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Voice-Code System                            │
│                                                                 │
│  ┌─────────┐    ┌──────────────┐    ┌───────────────┐          │
│  │   iOS   │◄──►│   Backend    │───►│  Claude CLI   │          │
│  │   App   │    │  (WebSocket) │◄───│   (stdout)    │          │
│  └─────────┘    └──────┬───────┘    └───────────────┘          │
│                        │                                        │
│                        ▼                                        │
│               ┌────────────────┐                                │
│               │ Voice-Code     │                                │
│               │ Session Store  │                                │
│               │ ~/.voice-code/ │                                │
│               └────────────────┘                                │
│                                                                 │
│  Optional Enhancement:                                          │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Global Stop Hook → POST /api/hook/stop                  │   │
│  │ (External session awareness - existence only)           │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘

                    ╳ NO DEPENDENCY ON ╳
              ~/.claude/projects/**/*.jsonl
```

### Data Model

#### Session Index

Location: `~/.voice-code/sessions/index.edn`

```clojure
{:version 1
 :sessions
 {"550e8400-e29b-41d4-a716-446655440000"
  {:session-id "550e8400-e29b-41d4-a716-446655440000"
   :name "Fix the login bug"
   :working-directory "/Users/user/project"  ;; Absolute path where session was created
   :created-at "2025-01-14T10:30:00.000Z"     ;; ISO-8601 string (serialized from Instant)
   :updated-at "2025-01-14T11:45:00.000Z"     ;; Updated on each message append
   :message-count 12
   :compacted? false
   :external? false}}}
```

**Note on timestamps:** All timestamps are stored as ISO-8601 strings for EDN compatibility. Use `(.toString (java.time.Instant/now))` for serialization and `(java.time.Instant/parse s)` for deserialization.

**Note on message IDs:** Message IDs are UUIDs generated via `(str (java.util.UUID/randomUUID))`, consistent with the existing `generate-message-id` function in `server.clj`.

#### Session History

Location: `~/.voice-code/sessions/<session-id>.edn`

```clojure
{:version 1
 :session-id "550e8400-e29b-41d4-a716-446655440000"
 :messages
 [{:id "550e8400-e29b-41d4-a716-446655440001"  ;; UUID, not sequential
   :role "user"
   :text "Fix the login bug in auth.clj"
   :timestamp "2025-01-14T10:30:00.000Z"}
  {:id "550e8400-e29b-41d4-a716-446655440002"
   :role "assistant"
   :text "I'll help you fix the login bug..."
   :timestamp "2025-01-14T10:30:45.000Z"
   :usage {:input-tokens 150 :output-tokens 500}
   :cost {:input-cost 0.0015 :output-cost 0.005 :total-cost 0.0065}}]}
```

#### External Sessions (Optional)

For sessions discovered via hooks but not initiated by voice-code:

```clojure
;; In index.edn, external sessions have limited metadata
{"external-uuid"
 {:session-id "external-uuid"
  :name nil  ; Unknown - not our session
  :working-directory "/Users/user/other-project"
  :last-activity "2025-01-14T12:00:00.000Z"
  :external? true}}
```

No history file exists for external sessions.

### API Design

#### New Namespace: `voice-code.session-store`

```clojure
(ns voice-code.session-store
  "Persistent storage for voice-code session history.
   Completely decoupled from Claude Code's internal formats."
  (:require [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.tools.logging :as log])
  (:import [java.time Instant]))

;; --- Configuration ---

(def ^:private sessions-dir
  "Directory for session storage. Can be overridden for testing."
  (atom (str (System/getProperty "user.home") "/.voice-code/sessions")))

(defn set-sessions-dir!
  "Set custom sessions directory (for testing)."
  [dir]
  (reset! sessions-dir dir))

;; --- Concurrency ---

(def ^:private index-lock
  "Lock for index file operations to prevent concurrent write corruption."
  (Object.))

;; --- Helper Functions ---

(defn- generate-message-id
  "Generate a unique message ID (UUID string)."
  []
  (str (java.util.UUID/randomUUID)))

(defn- timestamp-now
  "Generate current timestamp as ISO-8601 string."
  []
  (.toString (Instant/now)))

(defn- derive-name-from-prompt
  "Derive a session name from the first prompt text.
   Takes first 50 chars, truncates at word boundary if possible."
  [prompt-text]
  (when prompt-text
    (let [trimmed (clojure.string/trim prompt-text)
          max-len 50]
      (if (<= (count trimmed) max-len)
        trimmed
        (let [truncated (subs trimmed 0 max-len)
              last-space (.lastIndexOf truncated " ")]
          (if (pos? last-space)
            (str (subs truncated 0 last-space) "...")
            (str truncated "...")))))))

;; --- Index Operations ---

(defn load-index
  "Load session index from disk. Returns empty index if file doesn't exist."
  []
  (let [index-file (io/file @sessions-dir "index.edn")]
    (if (.exists index-file)
      (edn/read-string (slurp index-file))
      {:version 1 :sessions {}})))

(defn save-index!
  "Atomically save session index to disk.
   Writes to temp file then renames to prevent corruption."
  [index]
  (locking index-lock
    (let [dir (io/file @sessions-dir)
          index-file (io/file dir "index.edn")
          temp-file (io/file dir (str "index.edn." (System/currentTimeMillis) ".tmp"))]
      (.mkdirs dir)
      (spit temp-file (pr-str index))
      (.renameTo temp-file index-file))))

(defn get-session-metadata
  "Get metadata for a session from the index. Returns nil if not found."
  [session-id]
  (get-in (load-index) [:sessions session-id]))

(defn list-sessions
  "List all sessions, optionally filtered.
   Options:
     :working-directory - filter by directory
     :limit - max results (default: no limit)
     :include-external? - include external sessions (default false)
   Returns sessions sorted by :updated-at descending."
  [& {:keys [working-directory limit include-external?]
      :or {include-external? false}}]
  (let [all-sessions (vals (:sessions (load-index)))
        filtered (cond->> all-sessions
                   (not include-external?) (remove :external?)
                   working-directory (filter #(= working-directory (:working-directory %)))
                   true (sort-by :updated-at #(compare %2 %1))
                   limit (take limit))]
    (vec filtered)))

;; --- Session History Operations ---

(defn- session-file-path
  "Get the file path for a session's history file."
  [session-id]
  (io/file @sessions-dir (str session-id ".edn")))

(defn load-session-history
  "Load full message history for a session.
   Returns nil if session file doesn't exist."
  [session-id]
  (let [f (session-file-path session-id)]
    (when (.exists f)
      (edn/read-string (slurp f)))))

(defn- save-session-history!
  "Save session history to disk."
  [session-id history]
  (let [f (session-file-path session-id)]
    (.mkdirs (.getParentFile f))
    (spit f (pr-str history))))

(defn append-message!
  "Append a message to session history. Updates index metadata.
   Message should have :role and :text. :id and :timestamp are auto-generated if missing."
  [session-id message]
  (locking index-lock
    (let [msg-with-defaults (merge {:id (generate-message-id)
                                    :timestamp (timestamp-now)}
                                   message)
          history (or (load-session-history session-id)
                      {:version 1 :session-id session-id :messages []})
          updated-history (update history :messages conj msg-with-defaults)
          index (load-index)
          updated-index (-> index
                            (update-in [:sessions session-id :message-count] (fnil inc 0))
                            (assoc-in [:sessions session-id :updated-at] (timestamp-now)))]
      (save-session-history! session-id updated-history)
      (save-index! updated-index)
      msg-with-defaults)))

(defn create-session!
  "Create a new session with initial metadata.
   Returns the created session metadata."
  [session-id {:keys [name working-directory]}]
  (locking index-lock
    (let [now (timestamp-now)
          metadata {:session-id session-id
                    :name name
                    :working-directory working-directory
                    :created-at now
                    :updated-at now
                    :message-count 0
                    :compacted? false
                    :external? false}
          index (load-index)
          updated-index (assoc-in index [:sessions session-id] metadata)
          history {:version 1 :session-id session-id :messages []}]
      (save-session-history! session-id history)
      (save-index! updated-index)
      metadata)))

(defn mark-compacted!
  "Mark a session as compacted. Optionally clear local history."
  [session-id & {:keys [clear-history?]}]
  (locking index-lock
    (let [index (load-index)
          updated-index (-> index
                            (assoc-in [:sessions session-id :compacted?] true)
                            (assoc-in [:sessions session-id :updated-at] (timestamp-now)))]
      (when clear-history?
        (let [history {:version 1 :session-id session-id :messages []}]
          (save-session-history! session-id history)
          (save-index! (assoc-in updated-index [:sessions session-id :message-count] 0))))
      (when-not clear-history?
        (save-index! updated-index)))))

;; --- External Session Tracking (Optional) ---

(defn record-external-activity!
  "Record that an external session had activity. Called from Stop hook.
   Only updates if session doesn't already exist in our index."
  [session-id working-directory]
  (locking index-lock
    (let [index (load-index)]
      (when-not (get-in index [:sessions session-id])
        (let [now (timestamp-now)
              metadata {:session-id session-id
                        :name nil
                        :working-directory working-directory
                        :last-activity now
                        :external? true}
              updated-index (assoc-in index [:sessions session-id] metadata)]
          (save-index! updated-index)
          metadata)))))
```

#### Modified Prompt Handler

The prompt handling in `server.clj` is modified within the existing `handle-message` function's `"prompt"` case branch. This is illustrative pseudo-code showing the key changes - the actual integration will modify the existing prompt handling logic:

```clojure
;; In handle-message, within the "prompt" case branch:
;; (This shows the NEW code to add, not a standalone function)

;; After validating prompt-text and determining session-id:
(let [claude-session-id (or resume-session-id new-session-id)
      is-new-session? (some? new-session-id)]
  
  ;; NEW: Create session in our store if new
  (when is-new-session?
    (session-store/create-session! claude-session-id
      {:name (session-store/derive-name-from-prompt prompt-text)
       :working-directory working-dir}))
  
  ;; NEW: Store user message before invoking Claude
  (session-store/append-message! claude-session-id
    {:role "user"
     :text prompt-text})
  ;; Note: :id and :timestamp are auto-generated by append-message!
  
  ;; Existing: Invoke Claude CLI (unchanged - already uses public API)
  (claude/invoke-claude-async
    final-prompt-text
    (fn [response]
      (try
        (if (:success response)
          (do
            ;; NEW: Store assistant response in our store
            (session-store/append-message! claude-session-id
              {:role "assistant"
               :text (:result response)
               :usage (:usage response)
               :cost {:input-cost (:input_cost (:cost response))
                      :output-cost (:output_cost (:cost response))
                      :total-cost (:total_cost (:cost response))}})
            
            ;; Existing: Send turn_complete to iOS
            (send-to-client! channel
              {:type :turn-complete
               :session-id claude-session-id}))
          
          ;; Existing: Handle error (unchanged)
          (send-to-client! channel
            {:type :error
             :message (:error response)
             :session-id claude-session-id}))
        (finally
          (repl/release-session-lock! claude-session-id))))
    
    :new-session-id new-session-id
    :resume-session-id resume-session-id
    :working-directory working-dir
    :timeout-ms 86400000
    :system-prompt system-prompt))
```

**Key changes from current code:**
1. Add `session-store/create-session!` call for new sessions
2. Add `session-store/append-message!` before invoking Claude (user message)
3. Add `session-store/append-message!` in callback (assistant response)
4. Remove dependency on `repl/` namespace for session data (keep only lock functions during transition)

#### New HTTP Endpoint for Hooks (Optional)

Add a new HTTP route in `server.clj` alongside the existing `/upload` endpoint:

```clojure
;; POST /api/hook/stop
;; Called by global Stop hook to notify of external session activity
;; 
;; Wire this into websocket-handler's HTTP path handling:
;;   (case (:uri request)
;;     "/upload" (handle-http-upload request channel)
;;     "/api/hook/stop" (handle-hook-stop request channel)
;;     ...)

(defn handle-hook-stop
  "Handle Stop hook notifications from external Claude sessions.
   Records session existence without storing conversation content."
  [request channel]
  (try
    (let [body (parse-json (slurp (:body request)))
          {:keys [session-id cwd]} body]
      (if (and session-id cwd)
        (do
          ;; Only record if not one of our sessions
          (when-not (session-store/get-session-metadata session-id)
            (log/info "Recording external session activity" 
                      {:session-id session-id :cwd cwd})
            (session-store/record-external-activity! session-id cwd))
          (http/send! channel
            {:status 200
             :headers {"Content-Type" "application/json"}
             :body (generate-json {:ok true})}))
        (http/send! channel
          {:status 400
           :headers {"Content-Type" "application/json"}
           :body (generate-json {:error "session_id and cwd required"})})))
    (catch Exception e
      (log/error e "Error handling hook stop")
      (http/send! channel
        {:status 500
         :headers {"Content-Type" "application/json"}
         :body (generate-json {:error (str "Internal error: " (ex-message e))})}))))
```

**Note:** This endpoint does NOT require Bearer token authentication since:
1. It only records session existence, not sensitive data
2. Hook scripts run locally on the same machine
3. Adding auth would complicate hook script setup

### Component Interactions

#### Prompt Flow (Voice-Code Session)

```
1. iOS sends prompt via WebSocket
   {"type": "prompt", "text": "Fix the bug", "session_id": null}

2. Backend generates session ID (or uses existing)
   session-id = "550e8400-..."

3. Backend creates session in our store
   session-store/create-session!

4. Backend stores user message
   session-store/append-message! {:role "user" ...}

5. Backend invokes Claude CLI
   claude --print --output-format json --session-id <id> "Fix the bug"

6. Claude CLI returns JSON via stdout
   [{"type": "result", "result": "I'll help...", "session_id": "..."}]

7. Backend parses response, stores assistant message
   session-store/append-message! {:role "assistant" ...}

8. Backend sends response to iOS via WebSocket
   {"type": "response", "success": true, "text": "I'll help..."}
```

#### Session List Flow

```
1. iOS sends refresh_sessions via WebSocket

2. Backend queries our index
   session-store/list-sessions

3. Backend sends session list to iOS
   {"type": "session_list", "sessions": [...]}
```

#### Subscribe Flow

```
1. iOS sends subscribe for session-id

2. Backend loads history from our store
   session-store/load-session-history session-id

3. Backend sends history to iOS
   {"type": "session_history", "messages": [...]}
```

### Hook Configuration (Optional Enhancement)

For external session awareness, install a global Stop hook:

**~/.claude/settings.json:**
```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "~/.voice-code/hooks/notify-stop.sh"
      }]
    }]
  }
}
```

**~/.voice-code/hooks/notify-stop.sh:**
```bash
#!/bin/bash
# Notify voice-code backend of session activity
# Only uses public hook payload fields: session_id, cwd
# Does NOT read transcript_path (internal implementation detail)

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id')
cwd=$(echo "$input" | jq -r '.cwd')

# Only notify if backend is running, fail silently otherwise
curl -s -X POST "http://localhost:${VOICE_CODE_PORT:-7865}/api/hook/stop" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\": \"$session_id\", \"cwd\": \"$cwd\"}" \
  2>/dev/null || true
```

### Migration Strategy

**Approach: Clean break**

- Existing sessions in Claude Code continue to work via `claude --resume`
- Voice-code iOS app starts with empty session list
- Users create new sessions via voice-code
- No JSONL import (avoids coupling to internal format)

**Alternative considered:** One-time JSONL import. Rejected because:
1. Still couples us to internal format (even if just once)
2. Adds complexity for temporary benefit
3. Clean break is simpler and more robust

## 4. Verification Strategy

### Testing Approach

#### Unit Tests

**File:** `backend/test/voice_code/session_store_test.clj`

```clojure
(ns voice-code.session-store-test
  (:require [clojure.test :refer :all]
            [voice-code.session-store :as store]
            [clojure.java.io :as io]))

;; --- Test Fixtures ---

(defn with-temp-sessions-dir
  "Fixture that creates a temp directory for session storage and cleans up after."
  [f]
  (let [temp-dir (io/file (System/getProperty "java.io.tmpdir")
                          (str "voice-code-test-" (System/currentTimeMillis)))]
    (.mkdirs temp-dir)
    (store/set-sessions-dir! (.getAbsolutePath temp-dir))
    (try
      (f)
      (finally
        ;; Clean up temp directory
        (doseq [file (reverse (file-seq temp-dir))]
          (.delete file))))))

(use-fixtures :each with-temp-sessions-dir)

;; --- Unit Tests ---

(deftest create-session-test
  (testing "creates session with metadata"
    (let [session-id (str (java.util.UUID/randomUUID))]
      (store/create-session! session-id
        {:name "Test Session"
         :working-directory "/tmp/test"})
      (is (= "Test Session" 
             (:name (store/get-session-metadata session-id))))
      (is (= "/tmp/test"
             (:working-directory (store/get-session-metadata session-id))))
      (is (= 0 (:message-count (store/get-session-metadata session-id))))
      (is (false? (:external? (store/get-session-metadata session-id)))))))

(deftest append-message-test
  (testing "appends messages and updates index"
    (let [session-id (str (java.util.UUID/randomUUID))]
      (store/create-session! session-id {:name "Test" :working-directory "/tmp"})
      
      ;; Append user message (timestamp auto-generated)
      (let [msg1 (store/append-message! session-id {:role "user" :text "Hello"})]
        (is (some? (:id msg1)) "Message ID should be auto-generated")
        (is (some? (:timestamp msg1)) "Timestamp should be auto-generated"))
      
      ;; Append assistant message
      (store/append-message! session-id {:role "assistant" :text "Hi there"})
      
      (is (= 2 (:message-count (store/get-session-metadata session-id))))
      (is (= 2 (count (:messages (store/load-session-history session-id)))))))
  
  (testing "preserves message order"
    (let [session-id (str (java.util.UUID/randomUUID))]
      (store/create-session! session-id {:name "Order Test" :working-directory "/tmp"})
      (store/append-message! session-id {:role "user" :text "First"})
      (store/append-message! session-id {:role "assistant" :text "Second"})
      (store/append-message! session-id {:role "user" :text "Third"})
      
      (let [messages (:messages (store/load-session-history session-id))]
        (is (= ["First" "Second" "Third"] (mapv :text messages)))))))

(deftest list-sessions-test
  (testing "filters by working directory"
    (store/create-session! "s1" {:name "A" :working-directory "/project-a"})
    (store/create-session! "s2" {:name "B" :working-directory "/project-b"})
    (store/create-session! "s3" {:name "C" :working-directory "/project-a"})
    
    (let [result (store/list-sessions :working-directory "/project-a")]
      (is (= 2 (count result)))
      (is (= #{"s1" "s3"} (set (map :session-id result))))))
  
  (testing "excludes external sessions by default"
    (store/create-session! "internal" {:name "Internal" :working-directory "/tmp"})
    (store/record-external-activity! "external" "/tmp")
    
    (let [result (store/list-sessions)]
      (is (= 1 (count result)))
      (is (= "internal" (:session-id (first result))))))
  
  (testing "includes external sessions when requested"
    (let [result (store/list-sessions :include-external? true)]
      (is (= 2 (count result))))))

(deftest external-session-test
  (testing "records external session with limited metadata"
    (store/record-external-activity! "ext-123" "/some/project")
    
    (let [meta (store/get-session-metadata "ext-123")]
      (is (:external? meta))
      (is (= "/some/project" (:working-directory meta)))
      (is (nil? (:name meta)))
      (is (nil? (store/load-session-history "ext-123")))))
  
  (testing "does not overwrite existing session"
    (store/create-session! "existing" {:name "Existing" :working-directory "/tmp"})
    (store/record-external-activity! "existing" "/other")
    
    (let [meta (store/get-session-metadata "existing")]
      (is (= "Existing" (:name meta)))
      (is (= "/tmp" (:working-directory meta)))
      (is (false? (:external? meta))))))

(deftest derive-name-from-prompt-test
  (testing "short prompts are preserved"
    (is (= "Fix the bug" (#'store/derive-name-from-prompt "Fix the bug"))))
  
  (testing "long prompts are truncated at word boundary"
    (let [long-prompt "This is a very long prompt that exceeds the fifty character limit we have set"
          result (#'store/derive-name-from-prompt long-prompt)]
      (is (<= (count result) 53))  ;; 50 + "..."
      (is (.endsWith result "...")))))

(deftest mark-compacted-test
  (testing "marks session as compacted"
    (let [session-id (str (java.util.UUID/randomUUID))]
      (store/create-session! session-id {:name "Test" :working-directory "/tmp"})
      (store/append-message! session-id {:role "user" :text "Hello"})
      
      (store/mark-compacted! session-id)
      
      (is (true? (:compacted? (store/get-session-metadata session-id))))
      (is (= 1 (:message-count (store/get-session-metadata session-id))))))
  
  (testing "clears history when requested"
    (let [session-id (str (java.util.UUID/randomUUID))]
      (store/create-session! session-id {:name "Test" :working-directory "/tmp"})
      (store/append-message! session-id {:role "user" :text "Hello"})
      
      (store/mark-compacted! session-id :clear-history? true)
      
      (is (true? (:compacted? (store/get-session-metadata session-id))))
      (is (= 0 (:message-count (store/get-session-metadata session-id))))
      (is (empty? (:messages (store/load-session-history session-id)))))))
```

#### Integration Tests

**File:** `backend/test/voice_code/session_store_integration_test.clj`

```clojure
(ns voice-code.session-store-integration-test
  (:require [clojure.test :refer :all]
            [voice-code.session-store :as store]
            [voice-code.claude :as claude]
            [clojure.java.io :as io]))

;; Use same temp directory fixture as unit tests
(defn with-temp-sessions-dir [f]
  (let [temp-dir (io/file (System/getProperty "java.io.tmpdir")
                          (str "voice-code-integration-test-" (System/currentTimeMillis)))]
    (.mkdirs temp-dir)
    (store/set-sessions-dir! (.getAbsolutePath temp-dir))
    (try
      (f)
      (finally
        (doseq [file (reverse (file-seq temp-dir))]
          (.delete file))))))

(use-fixtures :each with-temp-sessions-dir)

(deftest prompt-stores-messages-test
  (testing "prompt flow stores user and assistant messages"
    (let [session-id (str (java.util.UUID/randomUUID))
          prompt-text "Hello Claude"]
      
      ;; Simulate what handle-message does for a new session prompt
      ;; Note: derive-name-from-prompt is private, use #' to access for testing
      (store/create-session! session-id 
        {:name (#'store/derive-name-from-prompt prompt-text)
         :working-directory "/tmp/test-project"})
      
      (store/append-message! session-id
        {:role "user" :text prompt-text})
      
      ;; Simulate callback after Claude responds
      (store/append-message! session-id
        {:role "assistant" 
         :text "Hi! I'm Claude. How can I help you?"
         :usage {:input-tokens 10 :output-tokens 20}
         :cost {:input-cost 0.001 :output-cost 0.002 :total-cost 0.003}})
      
      ;; Verify storage
      (let [history (store/load-session-history session-id)
            metadata (store/get-session-metadata session-id)]
        (is (= 2 (count (:messages history))))
        (is (= "user" (:role (first (:messages history)))))
        (is (= "assistant" (:role (second (:messages history)))))
        (is (= 2 (:message-count metadata)))
        (is (= "Hello Claude" (:name metadata)))))))

(deftest session-resume-preserves-history-test
  (testing "resuming a session preserves existing messages"
    (let [session-id (str (java.util.UUID/randomUUID))]
      ;; First turn
      (store/create-session! session-id {:name "Test" :working-directory "/tmp"})
      (store/append-message! session-id {:role "user" :text "First message"})
      (store/append-message! session-id {:role "assistant" :text "First response"})
      
      ;; Second turn (resume)
      (store/append-message! session-id {:role "user" :text "Second message"})
      (store/append-message! session-id {:role "assistant" :text "Second response"})
      
      (let [history (store/load-session-history session-id)]
        (is (= 4 (count (:messages history))))
        (is (= ["First message" "First response" "Second message" "Second response"]
               (mapv :text (:messages history))))))))
```

#### End-to-End Tests

1. iOS sends prompt → receives response → response stored in our format
2. iOS reconnects → subscribes to session → receives history from our store
3. iOS requests session list → receives list from our index

### Acceptance Criteria

1. [ ] Prompts sent via voice-code are stored in `~/.voice-code/sessions/`
2. [ ] Session list is loaded from our index, not Claude's directories
3. [ ] Session history is loaded from our files, not Claude's JSONL
4. [ ] No code reads from `~/.claude/projects/**/*.jsonl`
5. [ ] File watcher (`replication.clj`) is removed or disabled
6. [ ] Backend starts and operates without access to Claude's internal files
7. [ ] Existing Claude sessions continue to work via `--resume` (Claude CLI handles context)
8. [ ] (Optional) Global Stop hook notifies backend of external session activity

## 5. Alternatives Considered

### Alternative 1: Hybrid Approach (File Watcher + Hooks)

Keep file watcher for session discovery, use hooks for real-time updates.

**Rejected because:**
- Still coupled to file locations and format
- Added complexity without full decoupling
- Hooks alone can handle external session awareness

### Alternative 2: Parse JSONL On-Demand Only

Remove watching, but still parse JSONL when loading history.

**Rejected because:**
- Still coupled to JSONL format
- Format changes would still break history loading
- Doesn't achieve full decoupling goal

### Alternative 3: Use PostToolUse Hooks for Real-Time Updates

Send notifications after each tool use, not just at turn completion.

**Rejected for MVP because:**
- Adds complexity without critical benefit
- Stop hook is sufficient for turn-complete notification
- Can add later if needed for progress indication

### Chosen Approach: Own Our Data

Store conversation history ourselves, use CLI stdout as data source.

**Why chosen:**
- Complete decoupling from internal formats
- Maximum simplicity
- We control the schema
- Aligns with "producers not consumers" principle

**Trade-offs:**
- External sessions have limited visibility
- Pre-migration sessions not visible in iOS
- Slight disk space duplication (our files + Claude's files)

## 6. Risks & Mitigations

### Risk 1: CLI JSON Output Format Changes

**Risk:** Claude Code changes `--output-format json` schema.

**Mitigation:**
- This is the public API; breaking changes should be documented
- Parse defensively, handle missing fields gracefully
- Log unknown fields for debugging
- The JSON output format is much more stable than internal file formats

### Risk 2: Session ID Format Changes

**Risk:** Claude Code changes session ID format from UUIDs.

**Mitigation:**
- Treat session IDs as opaque strings
- Don't validate format, just store and pass through

### Risk 3: Users Miss Pre-Migration Sessions

**Risk:** Users expect to see their existing Claude sessions in iOS.

**Mitigation:**
- Document the clean break in release notes
- Existing sessions still work via `claude --resume` in terminal
- Voice-code is for voice-code sessions

### Risk 4: Disk Space from Duplicate Storage

**Risk:** Storing history ourselves duplicates Claude's JSONL storage.

**Mitigation:**
- Disk is cheap; our files are small (text only)
- Could add periodic cleanup if needed
- Trade-off is worth it for decoupling

### Rollback Strategy

If issues arise:
1. Re-enable file watcher code (kept in git history)
2. Fall back to reading Claude's JSONL
3. Our session storage can coexist with file watcher

Detection:
- Monitor for session storage write failures
- Alert on missing session history when subscribing
- Log CLI response parsing errors

---

## Appendix: Files to Modify/Remove

### Remove
- `backend/src/voice_code/replication.clj` - File watcher, JSONL parsing

### Add
- `backend/src/voice_code/session_store.clj` - New session storage namespace
- `backend/test/voice_code/session_store_test.clj` - Unit tests for session store
- `backend/test/voice_code/session_store_integration_test.clj` - Integration tests

### Modify
- `backend/src/voice_code/server.clj` - Use session store instead of replication
  - Add `[voice-code.session-store :as session-store]` to requires
  - Modify `"prompt"` case in `handle-message` to store messages
  - Modify `"connect"` and `"refresh_sessions"` to use `session-store/list-sessions`
  - Modify `"subscribe"` to use `session-store/load-session-history`
  - Add `handle-hook-stop` function and route (optional)
- `backend/src/voice_code/claude.clj` - No changes (already uses public API)

### Add (Optional)
- `~/.voice-code/hooks/notify-stop.sh` - Global Stop hook script
- HTTP route `/api/hook/stop` in `websocket-handler`

### Storage Locations (Runtime)
- `~/.voice-code/sessions/index.edn` - Session index
- `~/.voice-code/sessions/<uuid>.edn` - Per-session history files
