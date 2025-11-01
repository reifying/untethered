#!/bin/bash
# publish-testflight.sh - Automated TestFlight publishing script for VoiceCode
# Usage:
#   ./scripts/publish-testflight.sh publish  # Complete workflow
#   ./scripts/publish-testflight.sh export   # Export IPA only
#   ./scripts/publish-testflight.sh upload   # Upload IPA only

set -e  # Exit on error

# Configuration
SCHEME="VoiceCode"
PROJECT_PATH="ios/VoiceCode.xcodeproj"
ARCHIVE_PATH="build/archives/VoiceCode.xcarchive"
EXPORT_PATH="build/ipa"
IPA_PATH="build/ipa/VoiceCode.ipa"
EXPORT_OPTIONS_PLIST="build/ExportOptions.plist"
BUNDLE_ID="dev.910labs.voice-code"
TEAM_ID="REDACTED_TEAM_ID"

# App Store Connect API credentials (read from environment)
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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

# Get current version info
get_version_info() {
    cd ios
    VERSION=$(xcrun agvtool what-marketing-version -terse1)
    BUILD=$(xcrun agvtool what-version -terse)
    cd ..
    log_info "Current version: $VERSION ($BUILD)"
}

# Create ExportOptions.plist for App Store distribution
create_export_options() {
    log_info "Creating ExportOptions.plist..."
    mkdir -p build
    cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>signingStyle</key>
    <string>manual</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>$BUNDLE_ID</key>
        <string>REDACTED_PROVISIONING_UUID</string>
    </dict>
    <key>signingCertificate</key>
    <string>Apple Distribution</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
EOF
}

# Create archive
create_archive() {
    log_info "Creating archive build..."

    # Clean previous builds
    if [ -d "$ARCHIVE_PATH" ]; then
        log_warn "Removing previous archive..."
        rm -rf "$ARCHIVE_PATH"
    fi

    mkdir -p build/archives

    xcodebuild archive \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -archivePath "$ARCHIVE_PATH" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        | grep -E "^\*\*|error:|warning:|note:|Archive succeeded"

    if [ ! -d "$ARCHIVE_PATH" ]; then
        log_error "Archive creation failed - archive not found at $ARCHIVE_PATH"
        exit 1
    fi

    log_info "Archive created successfully at $ARCHIVE_PATH"
}

# Export IPA
export_ipa() {
    log_info "Exporting IPA from archive..."

    if [ ! -d "$ARCHIVE_PATH" ]; then
        log_error "Archive not found at $ARCHIVE_PATH. Run 'make archive' first."
        exit 1
    fi

    # Clean previous export
    if [ -d "$EXPORT_PATH" ]; then
        log_warn "Removing previous export..."
        rm -rf "$EXPORT_PATH"
    fi

    mkdir -p "$EXPORT_PATH"
    create_export_options

    # Export with local certificate and provisioning profile
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
        | grep -E "^\*\*|error:|warning:|note:|Export succeeded"

    if [ ! -f "$IPA_PATH" ]; then
        log_error "IPA export failed - IPA not found at $IPA_PATH"
        exit 1
    fi

    log_info "IPA exported successfully to $IPA_PATH"

    # Show IPA info
    IPA_SIZE=$(du -h "$IPA_PATH" | cut -f1)
    log_info "IPA size: $IPA_SIZE"
}

# Upload to TestFlight
upload_to_testflight() {
    log_info "Uploading to TestFlight..."

    if [ ! -f "$IPA_PATH" ]; then
        log_error "IPA not found at $IPA_PATH. Run export first."
        exit 1
    fi

    get_version_info

    log_info "Uploading version $VERSION ($BUILD) to App Store Connect..."
    log_warn "This may take several minutes..."

    # Check for API keys
    if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ] || [ ! -f "$ASC_KEY_PATH" ]; then
        log_error "App Store Connect API keys not configured"
        log_info "Please set ASC_KEY_ID, ASC_ISSUER_ID, and ensure API key file exists"
        log_info "Alternative: You can use Apple Transporter app to upload $IPA_PATH manually"
        log_info "Download from: https://apps.apple.com/app/transporter/id1450874784"
        exit 1
    fi

    # Use xcrun altool to upload with API key authentication
    xcrun altool --upload-app \
        --type ios \
        --file "$IPA_PATH" \
        --apiKey "$ASC_KEY_ID" \
        --apiIssuer "$ASC_ISSUER_ID" \
        || {
            log_error "Upload failed!"
            log_info "Alternative: You can use Apple Transporter app to upload $IPA_PATH manually"
            log_info "Download from: https://apps.apple.com/app/transporter/id1450874784"
            exit 1
        }

    log_info "Upload complete!"
    log_info "Check App Store Connect for processing status: https://appstoreconnect.apple.com"
}

# Complete publish workflow
publish() {
    log_info "Starting complete TestFlight publish workflow..."
    get_version_info

    create_archive
    export_ipa
    upload_to_testflight
}

# Main script
case "${1:-}" in
    archive)
        create_archive
        ;;
    export)
        export_ipa
        ;;
    upload)
        upload_to_testflight
        ;;
    publish)
        publish
        ;;
    *)
        log_error "Usage: $0 {publish|archive|export|upload}"
        exit 1
        ;;
esac
