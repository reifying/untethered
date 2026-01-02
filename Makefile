# Makefile for voice-code project
# iOS and Backend targets

# iOS Configuration
SCHEME := VoiceCode
SIMULATOR_NAME := iPhone 16 Pro
SIMULATOR_OS := 18.6
DESTINATION := 'platform=iOS Simulator,name=$(SIMULATOR_NAME),OS=$(SIMULATOR_OS)'
IOS_DIR := ios
BACKEND_DIR := backend
WRAP := ./scripts/wrap-command

.PHONY: help test test-verbose test-quiet test-class test-method test-ui test-ui-crash build clean setup-simulator deploy-device generate-project show-destinations check-sdk xcode-add-files list-simulators
.PHONY: backend-test backend-test-manual-startup backend-test-manual-protocol backend-test-manual-watcher-new backend-test-manual-prompt-new backend-test-manual-prompt-resume backend-test-manual-broadcast backend-test-manual-errors backend-test-manual-real-data backend-test-manual-resources backend-test-manual-free backend-test-manual-all backend-clean backend-run backend-stop backend-stop-all backend-restart backend-nrepl backend-nrepl-stop
.PHONY: bump-build bump-build-simple archive export-ipa upload-testflight deploy-testflight

# Default target
help:
	@echo "Available targets:"
	@echo ""
	@echo "iOS targets:"
	@echo "  generate-project  - Generate Xcode project from project.yml (XcodeGen)"
	@echo "  test              - Run all iOS tests with standard output"
	@echo "  test-verbose      - Run all iOS tests with detailed output"
	@echo "  test-quiet        - Run all iOS tests with minimal output"
	@echo "  test-class        - Run specific test class (usage: make test-class CLASS=TestClassName)"
	@echo "  test-method       - Run specific test method (usage: make test-method CLASS=TestClassName METHOD=test_method_name)"
	@echo "  test-ui           - Run all UI tests"
	@echo "  test-ui-crash     - Run crash reproduction UI tests only"
	@echo "  test-integration  - Run integration test with real backend (requires backend + sessions)"
	@echo "  build             - Build the iOS project (auto-generates project first)"
	@echo "  clean             - Clean iOS build artifacts"
	@echo "  setup-simulator   - Create and boot simulator: $(SIMULATOR_NAME)"
	@echo "  deploy-device     - Build and install to connected iPhone (fast deployment)"
	@echo ""
	@echo "Backend server management:"
	@echo "  backend-run       - Start the backend server"
	@echo "  backend-stop      - Stop the backend server (Makefile-started instance only)"
	@echo "  backend-stop-all  - Stop ALL backend servers (including manually started instances)"
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
	@echo "  backend-test-manual-resources     - Test 11: Resources integration (FREE)"
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
	@echo "  deploy-testflight  - ⭐ Deploy new build: smart bump + archive + export + upload"
	@echo "  bump-build         - Smart bump: queries TestFlight for latest build number"
	@echo "  bump-build-simple  - Simple increment (may conflict across branches)"
	@echo "  archive            - Create iOS archive for distribution"
	@echo "  export-ipa         - Export IPA from archive"
	@echo "  upload-testflight  - Upload IPA to TestFlight"
	@echo ""
	@echo "Debugging:"
	@echo "  show-destinations  - Show available build destinations"
	@echo "  check-sdk          - Show iOS SDK version info"
	@echo ""
	@echo "API Key Management:"
	@echo "  show-key           - Display the current API key"
	@echo "  show-key-qr        - Display API key with QR code for iOS scanning"
	@echo "  regenerate-key     - Generate a new API key (invalidates old key)"

# Ensure simulator exists and is booted
setup-simulator:
	@echo "Setting up simulator: $(SIMULATOR_NAME)"
	@xcrun simctl boot "$(SIMULATOR_NAME)" 2>/dev/null || true
	@echo "Simulator ready"

# Run tests with standard output
test: generate-project setup-simulator
	$(WRAP) bash -c "cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION)"

# Run tests with verbose output (shows all test execution details)
test-verbose: generate-project setup-simulator
	$(WRAP) bash -c "cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION) -verbose"

# Run tests with minimal output (just results)
test-quiet: generate-project setup-simulator
	@echo "Running tests..."
	@cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION) 2>&1 | grep -E "(Test Suite|Test Case.*passed|Test Case.*failed|Executed.*tests|Failing tests:)" || true
	@echo "Test run complete."

# Generate Xcode project from project.yml (XcodeGen)
generate-project:
	@echo "Generating Xcode project from project.yml..."
	cd $(IOS_DIR) && xcodegen generate
	@echo "✅ Project generated successfully"

# Build the project and compile tests
build: generate-project setup-simulator
	$(WRAP) bash -c "cd $(IOS_DIR) && xcodebuild build -scheme $(SCHEME) -destination $(DESTINATION) && xcodebuild build-for-testing -scheme $(SCHEME) -destination $(DESTINATION)"

# Clean build artifacts
clean:
	cd $(IOS_DIR) && xcodebuild clean -scheme $(SCHEME)
	rm -rf ~/Library/Developer/Xcode/DerivedData/VoiceCode-*

# Run specific test class (usage: make test-class CLASS=OptimisticUITests)
test-class: generate-project setup-simulator
ifndef CLASS
	$(error CLASS is required. Usage: make test-class CLASS=OptimisticUITests)
endif
	$(WRAP) bash -c "cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION) -only-testing:VoiceCodeTests/$(CLASS)"

# Run specific test method (usage: make test-method CLASS=OptimisticUITests METHOD=testCreateOptimisticMessage)
test-method: generate-project setup-simulator
ifndef CLASS
	$(error CLASS is required. Usage: make test-method CLASS=OptimisticUITests METHOD=test_method_name)
endif
ifndef METHOD
	$(error METHOD is required. Usage: make test-method CLASS=OptimisticUITests METHOD=test_method_name)
endif
	$(WRAP) bash -c "cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION) -only-testing:VoiceCodeTests/$(CLASS)/$(METHOD)"

# Run all UI tests
test-ui: setup-simulator
	$(WRAP) bash -c "cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION) -only-testing:VoiceCodeUITests"

# Run crash reproduction UI tests
test-ui-crash: setup-simulator
	$(WRAP) bash -c "cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION) -only-testing:VoiceCodeUITests/VoiceCodeUITests/testRapidTextInputNoCrash -only-testing:VoiceCodeUITests/VoiceCodeUITests/testTypeImmediatelyAfterViewAppearsNoCrash"

# Run simple crash test (no backend required)
test-crash-simple: setup-simulator
	$(WRAP) bash -c "cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION) -only-testing:VoiceCodeUITests/SimpleCrashTest"

# Run integration test with real backend (requires backend running and sessions)
test-integration: setup-simulator
	@echo "⚠️  This test requires:"
	@echo "   1. Backend running (make backend-run)"
	@echo "   2. At least one session exists"
	@echo ""
	$(WRAP) bash -c "cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION) -only-testing:VoiceCodeUITests/CrashReproductionTest"

# Build and install to connected iPhone (mimics Xcode's Run button)
deploy-device:
	@echo "Building and deploying to connected iPhone..."
	@echo "Make sure your iPhone is connected via USB and unlocked"
	$(WRAP) bash -c "cd $(IOS_DIR) && xcodebuild build -scheme $(SCHEME) -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath build CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=REDACTED_TEAM_ID"
	@echo "Installing to device..."
	cd $(IOS_DIR) && xcrun devicectl device install app --device $$(xcrun devicectl list devices | grep -i "iphone" | grep -E "(connected|available)" | grep -o '[0-9A-F]\{8\}-[0-9A-F]\{4\}-[0-9A-F]\{4\}-[0-9A-F]\{4\}-[0-9A-F]\{12\}' | head -1) build/Build/Products/Debug-iphoneos/VoiceCode.app
	@echo "✅ Deployed to iPhone! Launch the app manually."

# Backend targets

# Run regular automated tests (free, no Claude invocations)
backend-test:
	$(WRAP) bash -c "cd $(BACKEND_DIR) && clojure -M:test"

# Individual manual tests

backend-test-manual-startup:
	@echo "Running Test 3: Backend Startup & Session Discovery (FREE)"
	$(WRAP) bash -c "cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-03-startup"

backend-test-manual-protocol:
	@echo "Running Test 4: WebSocket Protocol (FREE)"
	$(WRAP) bash -c "cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-04-protocol"

backend-test-manual-watcher-new:
	@echo "Running Test 5: Filesystem Watcher - New Session (COSTS MONEY)"
	@echo "Press Ctrl+C to cancel or Enter to continue..."
	@read confirm
	$(WRAP) bash -c "cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-05-watcher-new"

backend-test-manual-prompt-new:
	@echo "Running Test 6: Prompt Sending - New Session (COSTS MONEY)"
	@echo "Press Ctrl+C to cancel or Enter to continue..."
	@read confirm
	$(WRAP) bash -c "cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-06-prompt-new"

backend-test-manual-prompt-resume:
	@echo "Running Test 7: Prompt Sending - Resume Session (COSTS MONEY)"
	@echo "Press Ctrl+C to cancel or Enter to continue..."
	@read confirm
	$(WRAP) bash -c "cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-07-prompt-resume"

backend-test-manual-broadcast:
	@echo "Running Test 8: Multi-Client Broadcast (FREE)"
	$(WRAP) bash -c "cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-08-broadcast"

backend-test-manual-errors:
	@echo "Running Test 9: Error Handling (FREE)"
	$(WRAP) bash -c "cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-09-errors"

backend-test-manual-real-data:
	@echo "Running Test 10: Real Data Validation with 700+ sessions (FREE)"
	$(WRAP) bash -c "cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-10-real-data-validation"

backend-test-manual-resources:
	@echo "Running Test 11: Resources Integration (FREE)"
	$(WRAP) bash -c "cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-resources-integration"

# Run all free manual tests
backend-test-manual-free:
	@echo "Running all FREE manual tests (no Claude invocations)..."
	$(WRAP) bash -c "cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -r 'voice-code\.(test-(0[3489]|10)-.*|test-resources-integration)'"

# Run ALL manual tests (including paid)
backend-test-manual-all:
	@echo "WARNING: This will run tests that invoke Claude CLI and cost money!"
	@echo "Tests 5, 6, 7 will make Claude API calls."
	@echo "Press Ctrl+C to cancel or Enter to continue..."
	@read confirm
	$(WRAP) bash -c "cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test"

# Clean up test artifacts
backend-clean:
	cd $(BACKEND_DIR) && rm -f server.log
	cd $(BACKEND_DIR) && rm -f **/test-*.jsonl

# Backend server management
# Note: Uses PID file to track Makefile-started instance (typically port 8080)
#       Manually started instances (e.g., port 9999 for remote work) are not managed
backend-run:
	@echo "Starting voice-code backend server..."
	@cd $(BACKEND_DIR) && ./start-server.sh

backend-stop:
	@if [ -f $(BACKEND_DIR)/.backend-pid ]; then \
		echo "Stopping voice-code backend server (PID: $$(cat $(BACKEND_DIR)/.backend-pid))..."; \
		kill $$(cat $(BACKEND_DIR)/.backend-pid) 2>/dev/null || echo "Process already stopped"; \
		rm -f $(BACKEND_DIR)/.backend-pid; \
		echo "Backend server stopped"; \
	else \
		echo "No backend server running (no PID file found)"; \
	fi

backend-stop-all:
	@echo "Stopping ALL voice-code backend servers..."
	@pkill -f "clojure.*voice-code.*server" || echo "No servers running"
	@rm -f $(BACKEND_DIR)/.backend-pid

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

# Increment build number (queries TestFlight for latest to avoid conflicts)
bump-build:
	@echo "Smart build number bump (queries TestFlight)..."
	@$(WRAP) ./scripts/smart-bump-build.sh

# Simple increment (legacy, may cause conflicts on different branches)
bump-build-simple:
	@echo "Incrementing build number (simple)..."
	@cd $(IOS_DIR) && xcrun agvtool next-version -all
	@echo "\nNew build number:"
	@cd $(IOS_DIR) && xcrun agvtool what-version

# Create archive
archive:
	@echo "Creating archive build..."
	$(WRAP) ./scripts/publish-testflight.sh archive

# Export IPA from archive
export-ipa:
	@echo "Exporting IPA..."
	$(WRAP) ./scripts/publish-testflight.sh export

# Upload to TestFlight
upload-testflight:
	@echo "Uploading to TestFlight..."
	$(WRAP) ./scripts/publish-testflight.sh upload

# Complete publish workflow: archive -> export -> upload
publish-testflight:
	@echo "Starting complete TestFlight publish workflow..."
	$(WRAP) ./scripts/publish-testflight.sh publish

# Deploy new build: smart bump -> archive -> export -> upload
deploy-testflight: generate-project
	@echo "Deploying new build to TestFlight..."
	@$(MAKE) bump-build
	@$(WRAP) ./scripts/publish-testflight.sh publish
	@echo "✅ Deployment complete! Check App Store Connect in ~15 minutes."

# Debug target to show available destinations
show-destinations: generate-project
	@cd $(IOS_DIR) && xcodebuild -project VoiceCode.xcodeproj -scheme $(SCHEME) -showdestinations

# Debug target to check SDK info
check-sdk:
	@xcodebuild -version -sdk iphoneos

# API Key Management
show-key:
	@cd $(BACKEND_DIR) && clojure -M -e "(require '[voice-code.auth :as auth]) (if-let [key (auth/read-api-key)] (println (str \"API Key: \" key)) (println \"No API key found. Start the backend to generate one.\"))"

show-key-qr:
	@cd $(BACKEND_DIR) && clojure -M -e "(require '[voice-code.qr :as qr]) (qr/display-api-key true)"

regenerate-key:
	@echo "WARNING: This will invalidate your current API key."
	@echo "You will need to re-pair your iOS device."
	@read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	@rm -f ~/.voice-code/api-key
	@cd $(BACKEND_DIR) && clojure -M -e "(require '[voice-code.auth :as auth]) (auth/ensure-key-file!) (println \"New API key generated. Run 'make show-key' to display.\")"
