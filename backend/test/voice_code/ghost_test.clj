(ns voice-code.ghost-test
  "Unit tests for the pure helpers in voice-code.ghost.
   No tmux server or filesystem required — every tested function is pure."
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.string :as str]
            [voice-code.ghost :as ghost]
            [voice-code.replication :as repl]))

;; ============================================================================
;; gen-nonce
;; ============================================================================

(deftest gen-nonce-test
  (testing "format is \"gp-\" + 12 lowercase hex digits"
    (dotimes [_ 50]
      (let [n (ghost/gen-nonce)]
        (is (re-matches #"gp-[0-9a-f]{12}" n)
            (str "nonce did not match gp-<12 hex>: " n)))))
  (testing "nonces are unique across many invocations"
    (let [nonces (repeatedly 1000 ghost/gen-nonce)]
      (is (= 1000 (count (distinct nonces)))))))

;; ============================================================================
;; begin-marker / end-marker
;; ============================================================================

(deftest marker-test
  (testing "sentinels embed the nonce in the documented ASCII shape"
    (let [n "gp-abc123abc123"]
      (is (= "===GHOST-BEGIN:gp-abc123abc123===" (ghost/begin-marker n)))
      (is (= "===GHOST-END:gp-abc123abc123===" (ghost/end-marker n)))))
  (testing "begin and end markers are distinct"
    (let [n (ghost/gen-nonce)]
      (is (not= (ghost/begin-marker n) (ghost/end-marker n))))))

;; ============================================================================
;; build-meta-prompt
;; ============================================================================

(deftest build-meta-prompt-test
  (testing "carries marker, nonce, task, and both sentinels on one line"
    (let [n "gp-deadbeef0001"
          p (ghost/build-meta-prompt "add a /healthz endpoint" n)]
      (is (str/includes? p repl/ghost-fork-marker))
      (is (str/includes? p n))
      (is (str/includes? p "add a /healthz endpoint"))
      (is (str/includes? p (ghost/begin-marker n)))
      (is (str/includes? p (ghost/end-marker n)))
      (is (not (str/includes? p "\n"))
          "meta-prompt must be a single physical line for nudge delivery")))
  (testing "a multi-line / whitespace-laden task is collapsed to a single line"
    (let [n "gp-deadbeef0001"
          p (ghost/build-meta-prompt "line one\nline two\tindented   spaced" n)]
      (is (not (str/includes? p "\n"))
          "newlines in the task must not survive into the meta-prompt")
      (is (not (str/includes? p "\t")))
      (is (str/includes? p "line one line two indented spaced")
          "internal whitespace runs collapse to single spaces")))
  (testing "a nil task does not throw and yields a single line"
    (let [n "gp-deadbeef0001"
          p (ghost/build-meta-prompt nil n)]
      (is (string? p))
      (is (not (str/includes? p "\n"))))))

;; ============================================================================
;; extract-prompt
;; ============================================================================

(deftest extract-prompt-test
  (testing "extracts between sentinels and strips preamble"
    (let [n "gp-abc123abc123"
          txt (str "Let me write a prompt.\n"
                   "===GHOST-BEGIN:" n "===\n"
                   "Add a /healthz endpoint that returns 200.\n"
                   "===GHOST-END:" n "===")]
      (is (= "Add a /healthz endpoint that returns 200."
             (ghost/extract-prompt txt n)))))
  (testing "preserves multi-line prompt body between the sentinels"
    (let [n "gp-abc123abc123"
          txt (str (ghost/begin-marker n) "\n"
                   "Line one.\nLine two.\n"
                   (ghost/end-marker n))]
      (is (= "Line one.\nLine two." (ghost/extract-prompt txt n)))))
  (testing "uses the first BEGIN and the first END after it"
    (let [n "gp-abc123abc123"
          txt (str (ghost/begin-marker n) "\n"
                   "keep this\n"
                   (ghost/end-marker n) "\n"
                   "and ignore the second block\n"
                   (ghost/begin-marker n) "\n"
                   "discard\n"
                   (ghost/end-marker n))]
      (is (= "keep this" (ghost/extract-prompt txt n)))))
  (testing "missing closing sentinel -> nil"
    (let [n "gp-abc123abc123"]
      (is (nil? (ghost/extract-prompt (str "===GHOST-BEGIN:" n "===\nhalf") n)))))
  (testing "missing opening sentinel -> nil"
    (let [n "gp-abc123abc123"]
      (is (nil? (ghost/extract-prompt (str "no markers here\n===GHOST-END:" n "===") n)))))
  (testing "blank body -> nil"
    (let [n "gp-abc123abc123"]
      (is (nil? (ghost/extract-prompt
                 (str "===GHOST-BEGIN:" n "===\n   \n===GHOST-END:" n "===") n)))))
  (testing "nil assistant-text -> nil (no throw)"
    (is (nil? (ghost/extract-prompt nil "gp-abc123abc123"))))
  (testing "extracting build-meta-prompt's own nonce against the model's wrapped reply"
    (let [n (ghost/gen-nonce)
          reply (str "Sure, here it is.\n"
                     (ghost/begin-marker n) "\n"
                     "Refactor the auth module.\n"
                     (ghost/end-marker n))]
      (is (= "Refactor the auth module." (ghost/extract-prompt reply n))))))
