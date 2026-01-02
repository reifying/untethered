#!/bin/bash
# publish-macos-dmg.sh - Notarized DMG distribution for macOS app
# Usage:
#   ./scripts/publish-macos-dmg.sh publish       # Complete workflow: archive, create DMG, notarize, staple
#   ./scripts/publish-macos-dmg.sh archive       # Archive only
#   ./scripts/publish-macos-dmg.sh dmg           # Create DMG from archive (no notarization)
#   ./scripts/publish-macos-dmg.sh notarize      # Notarize existing DMG
#   ./scripts/publish-macos-dmg.sh staple        # Staple ticket to DMG
#   ./scripts/publish-macos-dmg.sh store-creds   # Store notarization credentials in keychain

set -e  # Exit on error

# Configuration
SCHEME="VoiceCodeDesktop"
PROJECT_PATH="macos/VoiceCodeDesktop.xcodeproj"
ARCHIVE_PATH="build/archives/VoiceCodeDesktop.xcarchive"
APP_PATH="build/VoiceCodeDesktop.app"
DMG_PATH="build/VoiceCodeDesktop.dmg"
BUNDLE_ID="dev.910labs.voice-code-desktop"
TEAM_ID="REDACTED_TEAM_ID"
KEYCHAIN_PROFILE="voice-code-notarization"

# App Store Connect API credentials (read from environment - preferred for CI)
# These are the same credentials used for TestFlight
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Get current version info from project.yml
get_version_info() {
    cd macos
    VERSION=$(grep "MARKETING_VERSION:" project.yml | sed 's/.*MARKETING_VERSION: //' | tr -d '"' | tr -d ' ')
    BUILD=$(grep "CURRENT_PROJECT_VERSION:" project.yml | sed 's/.*CURRENT_PROJECT_VERSION: //' | tr -d '"' | tr -d ' ')
    cd ..
    log_info "Current version: $VERSION ($BUILD)"
}

# Check for required certificate
check_signing_identity() {
    log_step "Checking for Developer ID Application certificate..."

    # Look for Developer ID Application certificate
    IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')

    if [ -z "$IDENTITY" ]; then
        log_error "Developer ID Application certificate not found in keychain"
        log_info "You need a 'Developer ID Application' certificate to distribute outside the App Store"
        log_info "Generate one at: https://developer.apple.com/account/resources/certificates"
        exit 1
    fi

    log_info "Found signing identity: $IDENTITY"
    export SIGNING_IDENTITY="$IDENTITY"
}

# Create archive with Developer ID signing
create_archive() {
    log_step "Creating archive build with Developer ID signing..."

    # Regenerate Xcode project from project.yml
    log_info "Generating Xcode project from project.yml..."
    cd macos && xcodegen generate && cd ..

    check_signing_identity

    # Clean previous builds
    if [ -d "$ARCHIVE_PATH" ]; then
        log_warn "Removing previous archive..."
        rm -rf "$ARCHIVE_PATH"
    fi

    mkdir -p build/archives

    # Archive for macOS with Developer ID signing
    xcodebuild archive \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -archivePath "$ARCHIVE_PATH" \
        -configuration Release \
        -destination 'platform=macOS' \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
        | grep -E "^\*\*|error:|warning:|note:|Archive succeeded"

    if [ ! -d "$ARCHIVE_PATH" ]; then
        log_error "Archive creation failed - archive not found at $ARCHIVE_PATH"
        exit 1
    fi

    log_info "Archive created successfully at $ARCHIVE_PATH"
}

# Export app from archive
export_app() {
    log_step "Exporting app from archive..."

    if [ ! -d "$ARCHIVE_PATH" ]; then
        log_error "Archive not found at $ARCHIVE_PATH. Run 'archive' first."
        exit 1
    fi

    # Clean previous export
    if [ -d "$APP_PATH" ]; then
        log_warn "Removing previous app..."
        rm -rf "$APP_PATH"
    fi

    # Create export options plist for Developer ID
    cat > build/ExportOptionsMacOS.plist <<EOF
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

    # Export the app
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "build" \
        -exportOptionsPlist "build/ExportOptionsMacOS.plist" \
        -allowProvisioningUpdates \
        | grep -E "^\*\*|error:|warning:|note:|Export succeeded"

    if [ ! -d "$APP_PATH" ]; then
        log_error "App export failed - app not found at $APP_PATH"
        exit 1
    fi

    log_info "App exported successfully to $APP_PATH"
}

# Create DMG from app
create_dmg() {
    log_step "Creating DMG..."

    if [ ! -d "$APP_PATH" ]; then
        log_error "App not found at $APP_PATH. Run 'archive' first."
        exit 1
    fi

    # Clean previous DMG
    if [ -f "$DMG_PATH" ]; then
        log_warn "Removing previous DMG..."
        rm -f "$DMG_PATH"
    fi

    get_version_info

    # Create a simple DMG with the app and Applications symlink
    TEMP_DMG="build/temp.dmg"
    DMG_VOLUME_NAME="Untethered"

    # Create a temporary directory for DMG contents
    TEMP_DIR="build/dmg_contents"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    # Copy app to temp directory
    cp -R "$APP_PATH" "$TEMP_DIR/"

    # Create Applications symlink
    ln -s /Applications "$TEMP_DIR/Applications"

    # Create DMG
    hdiutil create -volname "$DMG_VOLUME_NAME" \
        -srcfolder "$TEMP_DIR" \
        -ov -format UDZO \
        "$DMG_PATH"

    # Clean up
    rm -rf "$TEMP_DIR"

    if [ ! -f "$DMG_PATH" ]; then
        log_error "DMG creation failed"
        exit 1
    fi

    # Sign the DMG
    log_info "Signing DMG..."
    check_signing_identity
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"

    DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
    log_info "DMG created: $DMG_PATH ($DMG_SIZE)"
}

# Check for notarization credentials
check_notarization_creds() {
    # First check for API key credentials (preferred for CI)
    if [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] && [ -f "$ASC_KEY_PATH" ]; then
        log_info "Using App Store Connect API key for notarization"
        return 0
    fi

    # Fall back to keychain profile
    if xcrun notarytool info --keychain-profile "$KEYCHAIN_PROFILE" 2>/dev/null | grep -q "keychain-profile"; then
        log_info "Using keychain profile: $KEYCHAIN_PROFILE"
        return 0
    fi

    log_error "Notarization credentials not found"
    log_info ""
    log_info "Option 1: Set environment variables (recommended for CI):"
    log_info "  export ASC_KEY_ID=<your-key-id>"
    log_info "  export ASC_ISSUER_ID=<your-issuer-id>"
    log_info "  # Place API key at: ~/.appstoreconnect/private_keys/AuthKey_<key-id>.p8"
    log_info ""
    log_info "Option 2: Store credentials in keychain:"
    log_info "  ./scripts/publish-macos-dmg.sh store-creds"
    exit 1
}

# Store credentials in keychain
store_credentials() {
    log_step "Storing notarization credentials in keychain..."
    log_info "You'll need your Apple ID, an app-specific password, and team ID"
    log_info ""
    log_info "To create an app-specific password:"
    log_info "  1. Go to https://appleid.apple.com/account/manage"
    log_info "  2. Sign in and go to 'App-Specific Passwords'"
    log_info "  3. Generate a new password for 'voice-code-notarization'"
    log_info ""

    # notarytool will prompt interactively for Apple ID and password
    xcrun notarytool store-credentials "$KEYCHAIN_PROFILE" \
        --team-id "$TEAM_ID"

    log_info "Credentials stored in keychain profile: $KEYCHAIN_PROFILE"
}

# Notarize the DMG
notarize_dmg() {
    log_step "Submitting DMG for notarization..."

    if [ ! -f "$DMG_PATH" ]; then
        log_error "DMG not found at $DMG_PATH. Create it first."
        exit 1
    fi

    check_notarization_creds

    log_warn "Submitting to Apple Notary Service (this may take several minutes)..."

    # Build the notarytool command based on auth method
    if [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] && [ -f "$ASC_KEY_PATH" ]; then
        xcrun notarytool submit "$DMG_PATH" \
            --key "$ASC_KEY_PATH" \
            --key-id "$ASC_KEY_ID" \
            --issuer "$ASC_ISSUER_ID" \
            --wait
    else
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$KEYCHAIN_PROFILE" \
            --wait
    fi

    log_info "Notarization complete!"
}

# Staple the ticket to the DMG
staple_dmg() {
    log_step "Stapling notarization ticket to DMG..."

    if [ ! -f "$DMG_PATH" ]; then
        log_error "DMG not found at $DMG_PATH."
        exit 1
    fi

    xcrun stapler staple "$DMG_PATH"

    log_info "Ticket stapled successfully!"
    log_info "DMG is ready for distribution: $DMG_PATH"
}

# Verify the notarization
verify_notarization() {
    log_step "Verifying notarization..."

    if [ ! -f "$DMG_PATH" ]; then
        log_error "DMG not found at $DMG_PATH."
        exit 1
    fi

    # Check Gatekeeper assessment
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

    log_info "Verification complete - DMG passes Gatekeeper"
}

# Complete publish workflow
publish() {
    log_info "Starting complete macOS distribution workflow..."
    get_version_info

    create_archive
    export_app
    create_dmg
    notarize_dmg
    staple_dmg
    verify_notarization

    log_info ""
    log_info "✅ Distribution complete!"
    log_info "   DMG: $DMG_PATH"
    log_info "   Ready for distribution"
}

# Main script
case "${1:-}" in
    archive)
        create_archive
        export_app
        ;;
    dmg)
        create_dmg
        ;;
    notarize)
        notarize_dmg
        ;;
    staple)
        staple_dmg
        ;;
    verify)
        verify_notarization
        ;;
    store-creds)
        store_credentials
        ;;
    publish)
        publish
        ;;
    *)
        echo "Usage: $0 {publish|archive|dmg|notarize|staple|verify|store-creds}"
        echo ""
        echo "Commands:"
        echo "  publish      Complete workflow: archive, DMG, notarize, staple"
        echo "  archive      Create signed archive and export app"
        echo "  dmg          Create DMG from exported app"
        echo "  notarize     Submit DMG to Apple Notary Service"
        echo "  staple       Staple notarization ticket to DMG"
        echo "  verify       Verify DMG passes Gatekeeper"
        echo "  store-creds  Store notarization credentials in keychain"
        exit 1
        ;;
esac
