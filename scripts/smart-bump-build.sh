#!/bin/bash
# smart-bump-build.sh - Intelligent build number management for TestFlight
# Queries App Store Connect for the latest build number and sets local to latest + 1
# This prevents conflicts when deploying from different branches

set -e

# Configuration
BUNDLE_ID="dev.910labs.voice-code"
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Get current local version info from project.yml
get_local_version() {
    cd ios
    # Read version from project.yml (XcodeGen source of truth)
    LOCAL_VERSION=$(grep "MARKETING_VERSION:" project.yml | sed 's/.*MARKETING_VERSION: //' | tr -d '"' | tr -d ' ')
    LOCAL_BUILD=$(grep "CURRENT_PROJECT_VERSION:" project.yml | sed 's/.*CURRENT_PROJECT_VERSION: //' | tr -d '"' | tr -d ' ')
    cd ..
    log_info "Local version: $LOCAL_VERSION ($LOCAL_BUILD)"
}

# Get latest TestFlight build number from App Store Connect
get_remote_build() {
    log_info "Querying App Store Connect for latest build number..."

    # Check for API keys
    if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ] || [ ! -f "$ASC_KEY_PATH" ]; then
        log_error "App Store Connect API keys not configured"
        log_info "Set ASC_KEY_ID, ASC_ISSUER_ID, and ensure API key file exists"
        log_info "Falling back to simple increment (may cause conflicts)"
        return 1
    fi

    # Use Python script to query API (more reliable JWT generation)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Capture stderr separately to avoid mixing with output
    ERROR_FILE=$(mktemp)
    REMOTE_BUILD=$("$SCRIPT_DIR/get-latest-testflight-build.py" "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$BUNDLE_ID" 2>"$ERROR_FILE")
    SCRIPT_EXIT=$?

    # Check if script succeeded
    if [ $SCRIPT_EXIT -ne 0 ]; then
        log_warn "API query failed: $(cat "$ERROR_FILE")"
        rm -f "$ERROR_FILE"
        return 1
    fi
    rm -f "$ERROR_FILE"

    # Validate we got a number
    if ! [[ "$REMOTE_BUILD" =~ ^[0-9]+$ ]]; then
        log_warn "Could not retrieve remote build number (maybe no builds yet?)"
        return 1
    fi

    log_info "Latest build in TestFlight: $REMOTE_BUILD"
    echo "$REMOTE_BUILD"
}

# Set build number to specific value in project.yml
set_build_number() {
    local new_build=$1
    log_info "Setting build number to $new_build in project.yml..."
    cd ios
    # Update CURRENT_PROJECT_VERSION in project.yml
    sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $new_build/" project.yml
    cd ..
}

# Main logic
main() {
    log_info "Starting smart build number bump..."

    get_local_version

    # Try to get remote build number
    if REMOTE_BUILD=$(get_remote_build); then
        # Calculate next build number
        NEXT_BUILD=$((REMOTE_BUILD + 1))

        log_info "Next build number will be: $NEXT_BUILD"

        # Compare with local
        if [ "$LOCAL_BUILD" -ge "$NEXT_BUILD" ]; then
            log_warn "Local build ($LOCAL_BUILD) is already >= next required ($NEXT_BUILD)"
            log_info "Using local build + 1: $((LOCAL_BUILD + 1))"
            NEXT_BUILD=$((LOCAL_BUILD + 1))
        fi

        set_build_number "$NEXT_BUILD"
    else
        # Fallback: simple increment
        log_warn "Using fallback: incrementing local build number"
        NEXT_BUILD=$((LOCAL_BUILD + 1))
        set_build_number "$NEXT_BUILD"
    fi

    # Show final version
    echo ""
    log_info "Final version:"
    cd ios
    FINAL_VERSION=$(grep "MARKETING_VERSION:" project.yml | sed 's/.*MARKETING_VERSION: //' | tr -d '"' | tr -d ' ')
    FINAL_BUILD=$(grep "CURRENT_PROJECT_VERSION:" project.yml | sed 's/.*CURRENT_PROJECT_VERSION: //' | tr -d '"' | tr -d ' ')
    echo "Current version of project is:"
    echo "    $FINAL_VERSION ($FINAL_BUILD)"
    cd ..
}

main
