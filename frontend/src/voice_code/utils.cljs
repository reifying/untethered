(ns voice-code.utils
  "Utility functions for voice-code - pure functions without React Native dependencies.")

(defn format-relative-time
  "Format a timestamp as relative time (e.g., '2 hours ago').
   Can be used standalone or via the auto-updating relative-time-text component."
  [timestamp]
  (when timestamp
    (let [now (js/Date.)
          ts (if (instance? js/Date timestamp)
               timestamp
               (js/Date. timestamp))
          diff (- (.getTime now) (.getTime ts))
          minutes (Math/floor (/ diff 60000))
          hours (Math/floor (/ minutes 60))
          days (Math/floor (/ hours 24))]
      (cond
        (< minutes 1) "Just now"
        (< minutes 60) (str minutes " min ago")
        (< hours 24) (str hours " hour" (when (not= hours 1) "s") " ago")
        (< days 7) (str days " day" (when (not= days 1) "s") " ago")
        :else (.toLocaleDateString ts)))))

(defn format-relative-time-short
  "Format a timestamp as short relative time (e.g., '2h ago').
   Shorter format for more compact displays."
  [timestamp]
  (when timestamp
    (let [now (js/Date.)
          ts (if (instance? js/Date timestamp)
               timestamp
               (js/Date. timestamp))
          diff (- (.getTime now) (.getTime ts))
          minutes (Math/floor (/ diff 60000))
          hours (Math/floor (/ minutes 60))
          days (Math/floor (/ hours 24))]
      (cond
        (< minutes 1) "Just now"
        (< minutes 60) (str minutes "m ago")
        (< hours 24) (str hours "h ago")
        (< days 7) (str days "d ago")
        :else (.toLocaleDateString ts)))))

;; ============================================================================
;; Text Truncation for Message Display
;; ============================================================================
;; Matches iOS CDMessage.swift truncation behavior for UI rendering.

(def truncation-threshold
  "Truncate messages longer than this. Matches iOS CDMessage.truncationHalfLength * 2 = 500"
  500)

(def truncation-preview-chars
  "Number of chars to show at start and end of truncated messages."
  250)

(defn truncate-text
  "Truncate text with first N and last N chars, showing truncation count.
   Matches iOS CDMessage.displayText behavior.
   Returns {:truncated? bool :display-text string :full-text string :truncated-count int}"
  [text]
  (if (or (nil? text) (<= (count text) truncation-threshold))
    {:truncated? false
     :display-text text
     :full-text text
     :truncated-count 0}
    (let [total-len (count text)
          truncated-count (- total-len (* 2 truncation-preview-chars))
          first-part (subs text 0 truncation-preview-chars)
          last-part (subs text (- total-len truncation-preview-chars))]
      {:truncated? true
       :display-text (str first-part "\n\n...[" truncated-count " chars truncated]...\n\n" last-part)
       :full-text text
       :truncated-count truncated-count})))

;; ============================================================================
;; Cost and Usage Formatting
;; ============================================================================

(defn format-cost
  "Format cost as currency with appropriate precision.
   Returns nil for nil, zero, or negative values."
  [cost]
  (when (and cost (pos? cost))
    (if (< cost 0.01)
      (str "$" (.toFixed cost 4))
      (str "$" (.toFixed cost 2)))))

(defn format-usage-summary
  "Format usage/cost into a compact display string.
   Shows tokens and cost in a compact format like '1.2K in / 890 out • $0.02'"
  [usage cost]
  (when (or usage cost)
    (let [input-tokens (or (:input-tokens usage) 0)
          output-tokens (or (:output-tokens usage) 0)
          total-cost (:total-cost cost)
          ;; Format tokens with K suffix for thousands
          format-tokens (fn [n]
                          (if (>= n 1000)
                            (str (.toFixed (/ n 1000) 1) "K")
                            (str n)))
          parts (cond-> []
                  (pos? (+ input-tokens output-tokens))
                  (conj (str (format-tokens input-tokens) " in / "
                             (format-tokens output-tokens) " out"))
                  total-cost
                  (conj (format-cost total-cost)))]
      (when (seq parts)
        (clojure.string/join " • " parts)))))

;; ============================================================================
;; Content Block Extraction for Claude Messages
;; ============================================================================
;; These functions extract and summarize different content block types
;; from Claude messages, matching iOS SessionSyncManager.swift behavior.

(defn- format-content-size
  "Format byte size in human-readable format."
  [bytes]
  (cond
    (nil? bytes) nil
    (< bytes 1024) (str bytes " bytes")
    (< bytes (* 1024 1024)) (str (Math/round (/ bytes 1024)) "KB")
    :else (str (.toFixed (/ bytes (* 1024 1024)) 1) "MB")))

(defn summarize-tool-use
  "Summarize a tool_use content block.
   Returns: '🔧 toolName: param summary' format."
  [block]
  (let [tool-name (or (:name block) "Tool call")
        input (:input block)]
    (if (or (nil? input) (empty? input))
      (str "🔧 " tool-name)
      ;; Extract common parameter patterns for readable summary
      (let [param-summary (or
                           ;; File path
                           (when-let [path (or (:file-path input) (:path input))]
                             (last (clojure.string/split path #"/")))
                           ;; Pattern search
                           (when-let [pattern (:pattern input)]
                             (str "pattern \"" (subs pattern 0 (min 30 (count pattern)))
                                  (when (> (count pattern) 30) "...") "\""))
                           ;; Command
                           (when-let [cmd (:command input)]
                             (str (subs cmd 0 (min 40 (count cmd)))
                                  (when (> (count cmd) 40) "...")))
                           ;; Code
                           (when-let [code (:code input)]
                             (str (subs code 0 (min 40 (count code)))
                                  (when (> (count code) 40) "...")))
                           ;; Generic first key-value
                           (when-let [[k v] (first input)]
                             (let [v-str (str v)]
                               (str (name k) ": " (subs v-str 0 (min 30 (count v-str)))
                                    (when (> (count v-str) 30) "...")))))]
        (if param-summary
          (str "🔧 " tool-name ": " param-summary)
          (str "🔧 " tool-name))))))

(defn- extract-text-from-content-blocks
  "Extract text from an array of content blocks."
  [blocks]
  (->> blocks
       (filter #(= "text" (:type %)))
       (map :text)
       (clojure.string/join "\n")))

(defn summarize-tool-result
  "Summarize a tool_result content block.
   Returns: '✓ Result (size)' or '✗ Error: message' format."
  [block]
  (if (:is-error block)
    ;; Error case
    (let [content (:content block)
          error-text (cond
                       (string? content) content
                       (sequential? content) (extract-text-from-content-blocks content)
                       :else nil)
          error-msg (when error-text
                      (first (clojure.string/split-lines error-text)))
          truncated (when error-msg
                      (if (> (count error-msg) 60)
                        (str (subs error-msg 0 60) "...")
                        error-msg))]
      (if truncated
        (str "✗ Error: " truncated)
        "✗ Error"))
    ;; Success case - use character count (not bytes) for ClojureScript
    (let [content (:content block)
          size (cond
                 (string? content) (count content)
                 (sequential? content) (count (or (extract-text-from-content-blocks content) ""))
                 :else nil)
          formatted (format-content-size size)]
      (if formatted
        (str "✓ Result (" formatted ")")
        "✓ Result"))))

(defn summarize-thinking
  "Summarize a thinking content block.
   Returns: '💭 First 60 chars of thinking...' format."
  [block]
  (let [thinking (:thinking block)]
    (if (or (nil? thinking) (empty? thinking))
      "💭 Thinking..."
      (let [max-length 60]
        (if (<= (count thinking) max-length)
          (str "💭 " thinking)
          ;; Try to break at word boundary
          (let [truncated (subs thinking 0 max-length)
                last-space (.lastIndexOf truncated " ")]
            (if (> last-space 0)
              (str "💭 " (subs truncated 0 last-space) "...")
              (str "💭 " truncated "..."))))))))

(defn extract-message-text
  "Extract displayable text from Claude message content blocks.
   Handles text, tool_use, tool_result, and thinking block types.
   Returns nil if no displayable content.
   
   Matches iOS SessionSyncManager.extractText behavior."
  [content]
  (cond
    ;; String content (user messages)
    (string? content) content

    ;; Array of content blocks (assistant messages)
    (sequential? content)
    (let [summaries (->> content
                         (map (fn [block]
                                (case (:type block)
                                  "text" (:text block)
                                  "tool_use" (summarize-tool-use block)
                                  "tool_result" (summarize-tool-result block)
                                  "thinking" (summarize-thinking block)
                                  ;; Unknown block type - show placeholder
                                  (str "[" (:type block) "]"))))
                         (remove nil?)
                         (remove empty?)
                         (vec))]
      (when (seq summaries)
        (clojure.string/join "\n\n" summaries)))

    ;; Fallback
    :else nil))

;; ============================================================================
;; Async Operation Timeout Utilities
;; ============================================================================

;; Registry of active timeout handles, keyed by operation-id.
;; Used to cancel timeouts when operations complete before timeout.
(defonce ^:private timeout-registry (atom {}))

(defn schedule-timeout!
  "Schedule a timeout callback. Returns the timeout handle.
   - operation-id: unique identifier for this timeout (e.g., [:compaction session-id])
   - timeout-ms: milliseconds until timeout fires
   - on-timeout: callback function to invoke on timeout
   
   The timeout is registered so it can be cancelled via cancel-timeout!"
  [operation-id timeout-ms on-timeout]
  (let [handle (js/setTimeout
                (fn []
                  ;; Remove from registry when fired
                  (swap! timeout-registry dissoc operation-id)
                  (on-timeout))
                timeout-ms)]
    (swap! timeout-registry assoc operation-id handle)
    handle))

(defn cancel-timeout!
  "Cancel a scheduled timeout by operation-id.
   Returns true if a timeout was cancelled, false if no timeout was found."
  [operation-id]
  (if-let [handle (get @timeout-registry operation-id)]
    (do
      (js/clearTimeout handle)
      (swap! timeout-registry dissoc operation-id)
      true)
    false))

(defn has-pending-timeout?
  "Check if there's a pending timeout for the given operation-id."
  [operation-id]
  (contains? @timeout-registry operation-id))

(defn debounce
  "Create a debounced function that delays invoking fn until after wait-ms
   milliseconds have elapsed since the last time the debounced function was called.
   
   Returns a map with:
   - :invoke - function to call (accepts any args, passes them to f)
   - :cancel - function to cancel any pending invocation
   
   Usage:
   (let [{:keys [invoke cancel]} (debounce #(println \"called\" %) 150)]
     (invoke \"a\")  ; scheduled
     (invoke \"b\")  ; cancels previous, schedules new
     ; after 150ms, prints \"called b\")"
  [f wait-ms]
  (let [timeout-handle (atom nil)]
    {:invoke (fn [& args]
               ;; Cancel any pending timeout
               (when-let [handle @timeout-handle]
                 (js/clearTimeout handle))
               ;; Schedule new timeout
               (reset! timeout-handle
                       (js/setTimeout
                        (fn []
                          (reset! timeout-handle nil)
                          (apply f args))
                        wait-ms)))
     :cancel (fn []
               (when-let [handle @timeout-handle]
                 (js/clearTimeout handle)
                 (reset! timeout-handle nil)))}))
