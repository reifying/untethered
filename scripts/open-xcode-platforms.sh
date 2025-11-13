#!/bin/bash
# open-xcode-platforms.sh - Opens Xcode to the Platforms/Components settings
# Usage: ./scripts/open-xcode-platforms.sh

set -e

echo "Opening Xcode Settings > Platforms..."
echo ""
echo "📱 Manual Steps:"
echo "1. Wait for Xcode to open"
echo "2. Look for 'Platforms' or 'Components' in the left sidebar"
echo "3. Find 'iOS' in the list"
echo "4. Click 'Download' or 'Install' if iOS 26.1 shows as not installed"
echo "5. Wait for installation to complete"
echo "6. Close Xcode"
echo "7. Run 'make archive' again"
echo ""

# Open Xcode
open -a Xcode

# Try to open settings directly (may not work in all Xcode versions)
sleep 2
osascript -e 'tell application "Xcode" to activate' 2>/dev/null || true
osascript -e 'tell application "System Events" to keystroke "," using command down' 2>/dev/null || true

echo "✅ Xcode opened. Navigate to Settings > Platforms manually."
