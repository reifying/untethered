#!/bin/bash
# Quick script to run resources-related tests
# Usage: ./scripts/test-resources.sh [option]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

function print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

function print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

function print_error() {
    echo -e "${RED}✗${NC} $1"
}

function show_help() {
    cat << EOF
Resources Feature Testing Script

Usage: $0 [option]

Options:
  automated      Run automated backend tests (fast, no setup)
  manual         Run manual integration test (requires backend running)
  ios            Run iOS tests for resources feature
  all            Run all tests (automated + iOS)
  help           Show this help message

Examples:
  $0 automated       # Quick backend tests
  $0 manual          # Interactive WebSocket testing
  $0 ios             # iOS unit/integration tests
  $0 all             # Everything automated

Notes:
  - Manual tests require backend server running (make backend-run)
  - iOS tests require iOS simulator setup
  - Manual test creates files on Desktop for inspection

EOF
}

function run_automated_tests() {
    print_header "Running Automated Backend Tests"

    cd backend

    print_warning "Running resources unit tests..."
    clojure -M:test -n voice-code.resources-test
    print_success "Unit tests passed"

    echo ""
    print_warning "Running resources integration tests..."
    clojure -M:test -n voice-code.resources-integration-test
    print_success "Integration tests passed"

    cd ..
    print_success "All automated backend tests passed!"
}

function run_manual_test() {
    print_header "Running Manual Integration Test"

    # Check if backend is running
    if ! nc -z localhost 8080 2>/dev/null; then
        print_error "Backend server not running on port 8080"
        echo ""
        echo "Start the backend in a separate terminal:"
        echo "  make backend-run"
        echo ""
        echo "Then run this script again."
        exit 1
    fi

    print_success "Backend server detected on port 8080"
    echo ""
    print_warning "Starting manual test..."
    print_warning "This will create test files on your Desktop"
    print_warning "You'll be prompted to inspect them before cleanup"
    echo ""

    cd backend
    clojure -M:manual-test -d manual_test -n voice-code.test-resources-integration
    cd ..

    print_success "Manual test completed"
}

function run_ios_tests() {
    print_header "Running iOS Resources Tests"

    print_warning "Setting up simulator..."
    make setup-simulator

    echo ""
    print_warning "Running ResourcesManagerTests..."
    make test-class CLASS=ResourcesManagerTests

    echo ""
    print_warning "Running ResourcesWebSocketIntegrationTests..."
    make test-class CLASS=ResourcesWebSocketIntegrationTests

    echo ""
    print_warning "Running ResourcesSettingsIntegrationTests..."
    make test-class CLASS=ResourcesSettingsIntegrationTests

    echo ""
    print_warning "Running ResourcesEndToEndTests..."
    make test-class CLASS=ResourcesEndToEndTests

    print_success "All iOS resources tests passed!"
}

function run_all_tests() {
    print_header "Running ALL Automated Tests"

    run_automated_tests
    echo ""
    run_ios_tests

    print_success "All tests passed! 🎉"
    echo ""
    print_warning "Note: Manual integration test not run (requires manual inspection)"
    print_warning "Run manually with: $0 manual"
}

# Main execution
case "${1:-help}" in
    automated)
        run_automated_tests
        ;;
    manual)
        run_manual_test
        ;;
    ios)
        run_ios_tests
        ;;
    all)
        run_all_tests
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        print_error "Unknown option: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
