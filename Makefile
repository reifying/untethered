# Makefile for voice-code iOS project
# Test automation and build targets

SCHEME := VoiceCode
SIMULATOR_NAME := iPhone 16 Pro
DESTINATION := 'platform=iOS Simulator,name=$(SIMULATOR_NAME)'
IOS_DIR := ios

.PHONY: test test-verbose test-quiet test-class test-method build clean help setup-simulator

# Default target
help:
	@echo "Available targets:"
	@echo "  test              - Run all tests with standard output"
	@echo "  test-verbose      - Run all tests with detailed output"
	@echo "  test-quiet        - Run all tests with minimal output"
	@echo "  test-class        - Run specific test class (usage: make test-class CLASS=TestClassName)"
	@echo "  test-method       - Run specific test method (usage: make test-method CLASS=TestClassName METHOD=test_method_name)"
	@echo "  build             - Build the project"
	@echo "  clean             - Clean build artifacts"
	@echo "  setup-simulator   - Create and boot simulator: $(SIMULATOR_NAME)"
	@echo "  help              - Show this help message"

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
