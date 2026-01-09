#!/bin/bash
# publish-mac.sh - Build, sign, notarize, and package Untethered for macOS distribution
# Usage:
#   ./scripts/publish-mac.sh build      # Build and sign only
#   ./scripts/publish-mac.sh notarize   # Notarize existing app
#   ./scripts/publish-mac.sh package    # Create zip for distribution
#   ./scripts/publish-mac.sh release    # Complete workflow (build → notarize → package)

set -e

# Configuration
SCHEME="VoiceCodeMac"
PROJECT_PATH="ios/VoiceCode.xcodeproj"
ARCHIVE_PATH="build/archives/Untethered.xcarchive"
EXPORT_PATH="build/mac"
APP_NAME="Untethered.app"
APP_PATH="$EXPORT_PATH/$APP_NAME"
ZIP_PATH="build/Untethered-mac.zip"
EXPORT_OPTIONS_PLIST="build/ExportOptionsMac.plist"
BUNDLE_ID="dev.910labs.voice-code-mac"
TEAM_ID="${TEAM_ID:-$DEVELOPMENT_TEAM}"

# Notarization credentials (from environment)
# Use app-specific password or keychain profile
APPLE_ID="${APPLE_ID:-}"
NOTARIZE_PASSWORD="${NOTARIZE_PASSWORD:-}"  # App-specific password
NOTARIZE_KEYCHAIN_PROFILE="${NOTARIZE_KEYCHAIN_PROFILE:-}"  # Or use keychain profile

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

get_version_info() {
    cd ios
    VERSION=$(grep "MARKETING_VERSION:" project.yml | sed 's/.*MARKETING_VERSION: //' | tr -d '"' | tr -d ' ')
    BUILD=$(grep "CURRENT_PROJECT_VERSION:" project.yml | sed 's/.*CURRENT_PROJECT_VERSION: //' | tr -d '"' | tr -d ' ')
    cd ..
    log_info "Version: $VERSION (build $BUILD)"
}

create_export_options() {
    log_info "Creating ExportOptions.plist for Developer ID distribution..."
    mkdir -p build
    cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF
}

build_app() {
    log_step "Building and signing Untethered.app..."

    if [ -z "$TEAM_ID" ]; then
        log_error "TEAM_ID or DEVELOPMENT_TEAM environment variable required"
        exit 1
    fi

    get_version_info

    # Regenerate Xcode project
    log_info "Generating Xcode project from project.yml..."
    cd ios && xcodegen generate && cd ..

    # Clean previous builds
    rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
    mkdir -p build/archives "$EXPORT_PATH"

    create_export_options

    # Archive for macOS
    log_info "Creating archive..."
    xcodebuild archive \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -archivePath "$ARCHIVE_PATH" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        | grep -E "^\*\*|error:|warning:|Archive Succeeded" || true

    if [ ! -d "$ARCHIVE_PATH" ]; then
        log_error "Archive creation failed"
        exit 1
    fi

    # Export with Developer ID signing
    log_info "Exporting with Developer ID signature..."
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
        | grep -E "^\*\*|error:|warning:|Export Succeeded" || true

    # The exported app might have a different name, find it
    EXPORTED_APP=$(find "$EXPORT_PATH" -name "*.app" -maxdepth 1 | head -1)
    if [ -z "$EXPORTED_APP" ]; then
        log_error "Export failed - no .app found in $EXPORT_PATH"
        exit 1
    fi

    # Rename to Untethered.app if needed
    if [ "$EXPORTED_APP" != "$APP_PATH" ]; then
        mv "$EXPORTED_APP" "$APP_PATH"
    fi

    log_info "App built and signed: $APP_PATH"

    # Verify signature
    log_info "Verifying code signature..."
    codesign -vvv --deep --strict "$APP_PATH"

    # Show signing info
    codesign -dvv "$APP_PATH" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier"
}

notarize_app() {
    log_step "Notarizing Untethered.app..."

    if [ ! -d "$APP_PATH" ]; then
        log_error "App not found at $APP_PATH. Run 'build' first."
        exit 1
    fi

    # Create zip for notarization
    NOTARIZE_ZIP="build/Untethered-notarize.zip"
    log_info "Creating zip for notarization..."
    ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

    # Submit for notarization
    log_info "Submitting to Apple notary service..."

    if [ -n "$NOTARIZE_KEYCHAIN_PROFILE" ]; then
        # Use stored keychain credentials
        xcrun notarytool submit "$NOTARIZE_ZIP" \
            --keychain-profile "$NOTARIZE_KEYCHAIN_PROFILE" \
            --wait
    elif [ -n "$APPLE_ID" ] && [ -n "$NOTARIZE_PASSWORD" ]; then
        # Use Apple ID + app-specific password
        xcrun notarytool submit "$NOTARIZE_ZIP" \
            --apple-id "$APPLE_ID" \
            --password "$NOTARIZE_PASSWORD" \
            --team-id "$TEAM_ID" \
            --wait
    else
        log_error "Notarization credentials required."
        log_info "Option 1: Set NOTARIZE_KEYCHAIN_PROFILE (recommended)"
        log_info "  Run: xcrun notarytool store-credentials --apple-id YOUR_APPLE_ID --team-id $TEAM_ID"
        log_info ""
        log_info "Option 2: Set APPLE_ID and NOTARIZE_PASSWORD (app-specific password)"
        log_info "  Generate at: https://appleid.apple.com/account/manage"
        exit 1
    fi

    # Staple the notarization ticket to the app
    log_info "Stapling notarization ticket..."
    xcrun stapler staple "$APP_PATH"

    # Verify notarization
    log_info "Verifying notarization..."
    xcrun stapler validate "$APP_PATH"
    spctl -a -vvv -t install "$APP_PATH"

    # Clean up notarization zip
    rm -f "$NOTARIZE_ZIP"

    log_info "Notarization complete!"
}

package_app() {
    log_step "Creating distribution package..."

    if [ ! -d "$APP_PATH" ]; then
        log_error "App not found at $APP_PATH. Run 'build' first."
        exit 1
    fi

    get_version_info

    # Create versioned zip name
    VERSIONED_ZIP="build/Untethered-${VERSION}-mac.zip"

    log_info "Creating $VERSIONED_ZIP..."
    rm -f "$ZIP_PATH" "$VERSIONED_ZIP"

    # Create zip preserving resource forks and metadata
    cd "$EXPORT_PATH"
    ditto -c -k --keepParent "$APP_NAME" "../Untethered-${VERSION}-mac.zip"
    cd - > /dev/null

    # Also create unversioned zip for Homebrew cask
    cp "$VERSIONED_ZIP" "$ZIP_PATH"

    # Calculate SHA256 for Homebrew
    SHA256=$(shasum -a 256 "$ZIP_PATH" | cut -d ' ' -f 1)

    log_info "Package created: $VERSIONED_ZIP"
    log_info "SHA256: $SHA256"
    log_info ""
    log_info "For Homebrew cask, use:"
    echo "  sha256 \"$SHA256\""
    echo "  url \"https://github.com/reifying/untethered/releases/download/v${VERSION}/Untethered-${VERSION}-mac.zip\""
}

release() {
    log_step "Starting complete release workflow..."
    get_version_info

    build_app
    notarize_app
    package_app

    log_info ""
    log_info "Release complete!"
    log_info "Upload build/Untethered-${VERSION}-mac.zip to GitHub Release v${VERSION}"
}

# Main
case "${1:-}" in
    build)
        build_app
        ;;
    notarize)
        notarize_app
        ;;
    package)
        package_app
        ;;
    release)
        release
        ;;
    *)
        echo "Usage: $0 {build|notarize|package|release}"
        echo ""
        echo "Commands:"
        echo "  build     - Build and sign with Developer ID"
        echo "  notarize  - Submit to Apple notary service"
        echo "  package   - Create zip for distribution"
        echo "  release   - Complete workflow (build → notarize → package)"
        echo ""
        echo "Environment variables:"
        echo "  TEAM_ID or DEVELOPMENT_TEAM - Apple Developer Team ID (required)"
        echo "  NOTARIZE_KEYCHAIN_PROFILE   - Keychain profile for notarization (recommended)"
        echo "  APPLE_ID                    - Apple ID for notarization (alternative)"
        echo "  NOTARIZE_PASSWORD           - App-specific password (alternative)"
        exit 1
        ;;
esac
