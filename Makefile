# Makefile for voice-code project
# iOS and Backend targets

# iOS Configuration
SCHEME := VoiceCode
SIMULATOR_NAME := iPhone 16 Pro
DESTINATION := 'platform=iOS Simulator,name=$(SIMULATOR_NAME)'
IOS_DIR := ios
BACKEND_DIR := backend

.PHONY: help test test-verbose test-quiet test-class test-method build clean setup-simulator deploy-device
.PHONY: backend-test backend-test-manual-startup backend-test-manual-protocol backend-test-manual-watcher-new backend-test-manual-prompt-new backend-test-manual-prompt-resume backend-test-manual-broadcast backend-test-manual-errors backend-test-manual-real-data backend-test-manual-free backend-test-manual-all backend-clean backend-run backend-stop backend-restart backend-nrepl backend-nrepl-stop
.PHONY: bump-build archive export-ipa upload-testflight publish-testflight deploy-testflight

# Default target
help:
	@echo "Available targets:"
	@echo ""
	@echo "iOS targets:"
	@echo "  test              - Run all iOS tests with standard output"
	@echo "  test-verbose      - Run all iOS tests with detailed output"
	@echo "  test-quiet        - Run all iOS tests with minimal output"
	@echo "  test-class        - Run specific test class (usage: make test-class CLASS=TestClassName)"
	@echo "  test-method       - Run specific test method (usage: make test-method CLASS=TestClassName METHOD=test_method_name)"
	@echo "  build             - Build the iOS project"
	@echo "  clean             - Clean iOS build artifacts"
	@echo "  setup-simulator   - Create and boot simulator: $(SIMULATOR_NAME)"
	@echo "  deploy-device     - Build and install to connected iPhone (fast deployment)"
	@echo ""
	@echo "Backend server management:"
	@echo "  backend-run       - Start the backend server"
	@echo "  backend-stop      - Stop the backend server"
	@echo "  backend-restart   - Restart the backend server"
	@echo "  backend-nrepl     - Start nREPL server (usage: make backend-nrepl [PORT=7888])"
	@echo "  backend-nrepl-stop - Stop nREPL server"
	@echo ""
	@echo "Backend testing:"
	@echo "  backend-test                      - Run automated backend tests (FREE)"
	@echo ""
	@echo "Backend manual tests (individual):"
	@echo "  backend-test-manual-startup       - Test 3: Backend startup (FREE)"
	@echo "  backend-test-manual-protocol      - Test 4: WebSocket protocol (FREE)"
	@echo "  backend-test-manual-watcher-new   - Test 5: Filesystem watcher (COSTS MONEY)"
	@echo "  backend-test-manual-prompt-new    - Test 6: Prompt new session (COSTS MONEY)"
	@echo "  backend-test-manual-prompt-resume - Test 7: Prompt resume session (COSTS MONEY)"
	@echo "  backend-test-manual-broadcast     - Test 8: Multi-client broadcast (FREE)"
	@echo "  backend-test-manual-errors        - Test 9: Error handling (FREE)"
	@echo "  backend-test-manual-real-data     - Test 10: Real data validation with 700+ sessions (FREE)"
	@echo ""
	@echo "Backend manual test suites:"
	@echo "  backend-test-manual-free          - Run all FREE manual tests"
	@echo "  backend-test-manual-all           - Run ALL manual tests (COSTS MONEY)"
	@echo ""
	@echo "Utility:"
	@echo "  backend-clean     - Remove backend test artifacts"
	@echo "  help              - Show this help message"
	@echo ""
	@echo "TestFlight publishing:"
	@echo "  deploy-testflight  - ⭐ Deploy new build: bump + archive + export + upload"
	@echo "  bump-build         - Increment iOS build number"
	@echo "  publish-testflight - Archive + export + upload (no bump)"
	@echo "  archive            - Create iOS archive for distribution"
	@echo "  export-ipa         - Export IPA from archive"
	@echo "  upload-testflight  - Upload IPA to TestFlight"

# Ensure simulator exists and is booted
setup-simulator:
	@echo "Setting up simulator: $(SIMULATOR_NAME)"
	@xcrun simctl boot "$(SIMULATOR_NAME)" 2>/dev/null || true
	@echo "Simulator ready"

# Run tests with standard output
test: setup-simulator
	cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION)

# Run tests with verbose output (shows all test execution details)
test-verbose: setup-simulator
	cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION) -verbose

# Run tests with minimal output (just results)
test-quiet: setup-simulator
	@echo "Running tests..."
	@cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION) 2>&1 | grep -E "(Test Suite|Test Case.*passed|Test Case.*failed|Executed.*tests|Failing tests:)" || true
	@echo "Test run complete."

# Build the project and compile tests
build: setup-simulator
	cd $(IOS_DIR) && xcodebuild build -scheme $(SCHEME) -destination $(DESTINATION)
	cd $(IOS_DIR) && xcodebuild build-for-testing -scheme $(SCHEME) -destination $(DESTINATION)

# Clean build artifacts
clean:
	cd $(IOS_DIR) && xcodebuild clean -scheme $(SCHEME)
	rm -rf ~/Library/Developer/Xcode/DerivedData/VoiceCode-*

# Run specific test class (usage: make test-class CLASS=OptimisticUITests)
test-class: setup-simulator
ifndef CLASS
	$(error CLASS is required. Usage: make test-class CLASS=OptimisticUITests)
endif
	cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION) -only-testing:VoiceCodeTests/$(CLASS)

# Run specific test method (usage: make test-method CLASS=OptimisticUITests METHOD=testCreateOptimisticMessage)
test-method: setup-simulator
ifndef CLASS
	$(error CLASS is required. Usage: make test-method CLASS=OptimisticUITests METHOD=test_method_name)
endif
ifndef METHOD
	$(error METHOD is required. Usage: make test-method CLASS=OptimisticUITests METHOD=test_method_name)
endif
	cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION) -only-testing:VoiceCodeTests/$(CLASS)/$(METHOD)

# Build and install to connected iPhone (mimics Xcode's Run button)
deploy-device:
	@echo "Building and deploying to connected iPhone..."
	@echo "Make sure your iPhone is connected via USB and unlocked"
	cd $(IOS_DIR) && xcodebuild build -scheme $(SCHEME) \
		-destination 'generic/platform=iOS' \
		-allowProvisioningUpdates \
		-derivedDataPath build
	@echo "Installing to device..."
	cd $(IOS_DIR) && xcrun devicectl device install app --device $$(xcrun devicectl list devices | grep -i "iphone" | grep "available" | grep -o '[0-9A-F]\{8\}-[0-9A-F]\{4\}-[0-9A-F]\{4\}-[0-9A-F]\{4\}-[0-9A-F]\{12\}' | head -1) build/Build/Products/Debug-iphoneos/VoiceCode.app
	@echo "✅ Deployed to iPhone! Launch the app manually."

# Backend targets

# Run regular automated tests (free, no Claude invocations)
backend-test:
	cd $(BACKEND_DIR) && clojure -M:test

# Individual manual tests

backend-test-manual-startup:
	@echo "Running Test 3: Backend Startup & Session Discovery (FREE)"
	cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-03-startup

backend-test-manual-protocol:
	@echo "Running Test 4: WebSocket Protocol (FREE)"
	cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-04-protocol

backend-test-manual-watcher-new:
	@echo "Running Test 5: Filesystem Watcher - New Session (COSTS MONEY)"
	@echo "Press Ctrl+C to cancel or Enter to continue..."
	@read confirm
	cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-05-watcher-new

backend-test-manual-prompt-new:
	@echo "Running Test 6: Prompt Sending - New Session (COSTS MONEY)"
	@echo "Press Ctrl+C to cancel or Enter to continue..."
	@read confirm
	cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-06-prompt-new

backend-test-manual-prompt-resume:
	@echo "Running Test 7: Prompt Sending - Resume Session (COSTS MONEY)"
	@echo "Press Ctrl+C to cancel or Enter to continue..."
	@read confirm
	cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-07-prompt-resume

backend-test-manual-broadcast:
	@echo "Running Test 8: Multi-Client Broadcast (FREE)"
	cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-08-broadcast

backend-test-manual-errors:
	@echo "Running Test 9: Error Handling (FREE)"
	cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-09-errors

backend-test-manual-real-data:
	@echo "Running Test 10: Real Data Validation with 700+ sessions (FREE)"
	cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-10-real-data-validation

# Run all free manual tests
backend-test-manual-free:
	@echo "Running all FREE manual tests (no Claude invocations)..."
	cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -r "voice-code\.test-(0[3489]|10)-.*"

# Run ALL manual tests (including paid)
backend-test-manual-all:
	@echo "WARNING: This will run tests that invoke Claude CLI and cost money!"
	@echo "Tests 5, 6, 7 will make Claude API calls."
	@echo "Press Ctrl+C to cancel or Enter to continue..."
	@read confirm
	cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test

# Clean up test artifacts
backend-clean:
	cd $(BACKEND_DIR) && rm -f server.log
	cd $(BACKEND_DIR) && rm -f **/test-*.jsonl

# Server management
backend-run:
	@echo "Starting voice-code backend server..."
	cd $(BACKEND_DIR) && clojure -M -m voice-code.server

backend-stop:
	@echo "Stopping voice-code backend server..."
	@pkill -f "clojure.*voice-code.*server" || echo "No server running"

backend-restart: backend-stop
	@echo "Waiting for server to stop..."
	@sleep 2
	@echo "Starting voice-code backend server..."
	@$(MAKE) backend-run

# nREPL server management
# Default port is 7888, can be overridden with PORT=<number>
PORT ?= 7888

backend-nrepl:
	@echo "Starting nREPL server on port $(PORT)..."
	@cd $(BACKEND_DIR) && clojure -M:nrepl -p $(PORT) &
	@echo "$$!" > $(BACKEND_DIR)/.nrepl-pid
	@echo "nREPL server started on port $(PORT) (PID: $$(cat $(BACKEND_DIR)/.nrepl-pid))"
	@echo "Port file: $(BACKEND_DIR)/.nrepl-port"

backend-nrepl-stop:
	@if [ -f $(BACKEND_DIR)/.nrepl-pid ]; then \
		echo "Stopping nREPL server (PID: $$(cat $(BACKEND_DIR)/.nrepl-pid))..."; \
		kill $$(cat $(BACKEND_DIR)/.nrepl-pid) 2>/dev/null || echo "Process already stopped"; \
		rm -f $(BACKEND_DIR)/.nrepl-pid; \
		rm -f $(BACKEND_DIR)/.nrepl-port; \
		echo "nREPL server stopped"; \
	else \
		echo "No nREPL server running (no PID file found)"; \
	fi

# TestFlight Publishing
# Requires: App Store Connect API keys set in environment (.envrc)
# See: docs/testflight-deployment-setup.md

# Increment build number
bump-build:
	@echo "Incrementing build number..."
	@cd $(IOS_DIR) && xcrun agvtool next-version -all
	@echo "\nNew build number:"
	@cd $(IOS_DIR) && xcrun agvtool what-version

# Create archive
archive:
	@echo "Creating archive build..."
	@./scripts/publish-testflight.sh archive

# Export IPA from archive
export-ipa:
	@echo "Exporting IPA..."
	@./scripts/publish-testflight.sh export

# Upload to TestFlight
upload-testflight:
	@echo "Uploading to TestFlight..."
	@bash -c 'source .envrc && ./scripts/publish-testflight.sh upload'

# Complete publish workflow: archive -> export -> upload
publish-testflight:
	@echo "Starting complete TestFlight publish workflow..."
	@bash -c 'source .envrc && ./scripts/publish-testflight.sh publish'

# Deploy new build: bump version -> archive -> export -> upload (most common workflow)
deploy-testflight:
	@echo "Deploying new build to TestFlight..."
	@$(MAKE) bump-build
	@bash -c 'source .envrc && $(MAKE) publish-testflight'
	@echo "✅ Deployment complete! Check App Store Connect in ~15 minutes."
