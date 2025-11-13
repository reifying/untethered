#!/bin/bash
# Script to test typing crash by automating simulator input

set -e

echo "Installing app to simulator..."
xcrun simctl install booted /Users/travisbrown/Library/Developer/Xcode/DerivedData/VoiceCode-fdcxegmcjjjluqcvkcghdyfssnwq/Build/Products/Debug-iphonesimulator/VoiceCode.app

echo "Launching app..."
xcrun simctl launch --console booted dev.910labs.voice-code &
APP_PID=$!

echo "Waiting for app to launch..."
sleep 3

echo "Attempting to type in simulator..."
echo "This will type 'test' character by character"

# Use simctl to send keystrokes
for char in t e s t; do
    echo "Typing: $char"
    xcrun simctl keyboardinput booted "$char"
    sleep 0.2
done

echo "Typed 'test' - checking if app crashed..."
sleep 1

# Check if app is still running
if xcrun simctl list | grep -q "Booted"; then
    if pgrep -q "VoiceCode"; then
        echo "✅ App still running - no crash detected"
        exit 0
    else
        echo "❌ App crashed!"
        exit 1
    fi
fi
