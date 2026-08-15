(ns voice-code.prompt-origin-test
  "Attribution of human-role prompts: backend-injected vs. typed by the user in
   the pane. This is the discriminator the iOS priority queue admits on, so the
   asymmetry matters — see the bias documented on voice-code.prompt-origin."
  (:require [clojure.test :refer [deftest testing is use-fixtures]]
            [voice-code.prompt-origin :as origin]
            [voice-code.replication :as repl]))

(use-fixtures :each (fn [f] (origin/reset-all!) (f) (origin/reset-all!)))

(def ^:private sid "11112222-3333-4444-5555-666666666666")

(deftest unrecorded-prompt-is-attributed-to-the-user
  (testing "nothing injected — the user typed it"
    (is (false? (origin/claim-injected! sid "go fix the flaky test"))
        "A human prompt with no matching injection is the user at the keyboard")))

(deftest injected-prompt-is-claimed
  (testing "recorded then observed"
    (origin/record-injected! sid "run the recipe step")
    (is (true? (origin/claim-injected! sid "run the recipe step")))))

(deftest claim-consumes-exactly-one-record
  (origin/record-injected! sid "same text")
  (is (true? (origin/claim-injected! sid "same text")))
  (is (false? (origin/claim-injected! sid "same text"))
      "A second identical human prompt with no second injection is the user"))

(deftest two-injections-yield-two-claims
  (origin/record-injected! sid "continue")
  (origin/record-injected! sid "continue")
  (is (true? (origin/claim-injected! sid "continue")))
  (is (true? (origin/claim-injected! sid "continue"))
      "Back-to-back identical injections must not collapse into one record")
  (is (false? (origin/claim-injected! sid "continue"))))

(deftest records-are-per-session
  (origin/record-injected! sid "supervisor work")
  (is (false? (origin/claim-injected! "other-session" "supervisor work")
              )
      "One agent's injection must never explain another agent's prompt")
  (is (true? (origin/claim-injected! sid "supervisor work"))))

(deftest matching-ignores-whitespace-differences
  (testing "the pane round-trip is not guaranteed to preserve exact whitespace"
    (origin/record-injected! sid "  fix   the\nbug  ")
    (is (true? (origin/claim-injected! sid "fix the bug")))))

(deftest unmatched-text-is-absorbed-while-an-injection-is-outstanding
  (testing "bias: an injection we failed to text-match beats 'the user typed it'"
    (origin/record-injected! sid "the prompt we sent")
    (is (true? (origin/claim-injected! sid "something that does not match"))
        "Outstanding injection absorbs the prompt rather than risk a false enrollment")
    (is (false? (origin/claim-injected! sid "and now the user really did type"))
        "…but only once — the record is consumed, so the next prompt reads as typed")))

(deftest expired-records-do-not-suppress-a-real-keyboard-prompt
  (testing "a prompt that never landed cannot mute the user forever"
    (origin/record-injected! sid "injected but never delivered")
    (with-redefs [origin/injection-ttl-ms -1]
      (is (false? (origin/claim-injected! sid "user typed this much later"))))))

(deftest empty-prompts-are-not-recorded
  (origin/record-injected! sid "   ")
  (origin/record-injected! sid nil)
  (is (zero? (origin/pending-count sid))
      "Blank text carries no attribution value and must not absorb a later prompt"))

(deftest clear-forgets-a-session
  (origin/record-injected! sid "pending")
  (origin/clear! sid)
  (is (zero? (origin/pending-count sid)))
  (is (false? (origin/claim-injected! sid "pending"))))

;; ---------------------------------------------------------------------------
;; human-prompt-text — the text extraction the classifier feeds on
;; ---------------------------------------------------------------------------

(deftest human-prompt-text-handles-both-content-shapes
  (testing "bare string content"
    (is (= "hello" (repl/human-prompt-text {:message {:content "hello"}}))))

  (testing "block content keeps only text blocks"
    (is (= "first\nsecond"
           (repl/human-prompt-text
            {:message {:content [{:type "text" :text "first"}
                                 {:type "image" :source {}}
                                 {:type "text" :text "second"}]}}))))

  (testing "no textual content yields empty string, never nil"
    (is (= "" (repl/human-prompt-text {:message {:content [{:type "image" :source {}}]}})))
    (is (= "" (repl/human-prompt-text {:message {}})))))

(deftest human-prompt-text-round-trips-through-attribution
  (testing "a block-content injection is claimable via the extracted text"
    (let [raw {:type "user"
               :message {:content [{:type "text" :text "do the thing"}]}}]
      (is (true? (repl/claude-human-prompt? raw)))
      (origin/record-injected! sid "do the thing")
      (is (true? (origin/claim-injected! sid (repl/human-prompt-text raw)))))))
