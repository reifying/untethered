.PHONY: test test-manual-startup test-manual-protocol test-manual-watcher-new test-manual-prompt-new test-manual-prompt-resume test-manual-broadcast test-manual-errors test-manual-free test-manual-all clean

# Run regular automated tests (free, no Claude invocations)
test:
	clojure -M:test

# Individual manual tests

test-manual-startup:
	@echo "Running Test 3: Backend Startup & Session Discovery (FREE)"
	clojure -M:manual-test -d manual_test -n voice-code.test-03-startup

test-manual-protocol:
	@echo "Running Test 4: WebSocket Protocol (FREE)"
	clojure -M:manual-test -d manual_test -n voice-code.test-04-protocol

test-manual-watcher-new:
	@echo "Running Test 5: Filesystem Watcher - New Session (COSTS MONEY)"
	@echo "Press Ctrl+C to cancel or Enter to continue..."
	@read confirm
	clojure -M:manual-test -d manual_test -n voice-code.test-05-watcher-new

test-manual-prompt-new:
	@echo "Running Test 6: Prompt Sending - New Session (COSTS MONEY)"
	@echo "Press Ctrl+C to cancel or Enter to continue..."
	@read confirm
	clojure -M:manual-test -d manual_test -n voice-code.test-06-prompt-new

test-manual-prompt-resume:
	@echo "Running Test 7: Prompt Sending - Resume Session (COSTS MONEY)"
	@echo "Press Ctrl+C to cancel or Enter to continue..."
	@read confirm
	clojure -M:manual-test -d manual_test -n voice-code.test-07-prompt-resume

test-manual-broadcast:
	@echo "Running Test 8: Multi-Client Broadcast (FREE)"
	clojure -M:manual-test -d manual_test -n voice-code.test-08-broadcast

test-manual-errors:
	@echo "Running Test 9: Error Handling (FREE)"
	clojure -M:manual-test -d manual_test -n voice-code.test-09-errors

# Run all free manual tests
test-manual-free:
	@echo "Running all FREE manual tests (no Claude invocations)..."
	clojure -M:manual-test -d manual_test -r "voice-code\.test-0[3489]-.*"

# Run ALL manual tests (including paid)
test-manual-all:
	@echo "WARNING: This will run tests that invoke Claude CLI and cost money!"
	@echo "Tests 5, 6, 7 will make Claude API calls."
	@echo "Press Ctrl+C to cancel or Enter to continue..."
	@read confirm
	clojure -M:manual-test -d manual_test

# Clean up test artifacts
clean:
	rm -f server.log
	rm -f **/test-*.jsonl

# Help
help:
	@echo "Available targets:"
	@echo "  test                      - Run automated tests (FREE)"
	@echo ""
	@echo "Manual tests (individual):"
	@echo "  test-manual-startup       - Test 3: Backend startup (FREE)"
	@echo "  test-manual-protocol      - Test 4: WebSocket protocol (FREE)"
	@echo "  test-manual-watcher-new   - Test 5: Filesystem watcher (COSTS MONEY)"
	@echo "  test-manual-prompt-new    - Test 6: Prompt new session (COSTS MONEY)"
	@echo "  test-manual-prompt-resume - Test 7: Prompt resume session (COSTS MONEY)"
	@echo "  test-manual-broadcast     - Test 8: Multi-client broadcast (FREE)"
	@echo "  test-manual-errors        - Test 9: Error handling (FREE)"
	@echo ""
	@echo "Manual test suites:"
	@echo "  test-manual-free          - Run all FREE manual tests"
	@echo "  test-manual-all           - Run ALL manual tests (COSTS MONEY)"
	@echo ""
	@echo "Utility:"
	@echo "  clean                     - Remove test artifacts"
	@echo "  help                      - Show this help message"
