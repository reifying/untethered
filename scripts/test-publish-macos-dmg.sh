#!/bin/bash
# test-publish-macos-dmg.sh - Tests for macOS DMG distribution script
# Usage: ./scripts/test-publish-macos-dmg.sh

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}✓${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

echo "Running publish-macos-dmg.sh tests..."
echo ""

# Test 1: Script exists and is executable
if [ -x "scripts/publish-macos-dmg.sh" ]; then
    pass "Script is executable"
else
    fail "Script is not executable or doesn't exist"
fi

# Test 2: Script has valid bash syntax
if bash -n scripts/publish-macos-dmg.sh 2>/dev/null; then
    pass "Script has valid bash syntax"
else
    fail "Script has syntax errors"
fi

# Test 3: Script shows help without error
if scripts/publish-macos-dmg.sh 2>&1 | grep -q "Usage:"; then
    pass "Script shows usage help"
else
    fail "Script doesn't show usage help"
fi

# Test 4: All required commands are defined
REQUIRED_COMMANDS="archive dmg notarize staple verify store-creds publish"
MISSING_COMMANDS=""
for cmd in $REQUIRED_COMMANDS; do
    if ! grep -q "^[[:space:]]*$cmd)" scripts/publish-macos-dmg.sh; then
        MISSING_COMMANDS="$MISSING_COMMANDS $cmd"
    fi
done

if [ -z "$MISSING_COMMANDS" ]; then
    pass "All required commands are defined: $REQUIRED_COMMANDS"
else
    fail "Missing commands:$MISSING_COMMANDS"
fi

# Test 5: Required tools are available
REQUIRED_TOOLS="xcodebuild codesign hdiutil xcrun"
MISSING_TOOLS=""
for tool in $REQUIRED_TOOLS; do
    if ! command -v $tool &>/dev/null; then
        MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
done

if [ -z "$MISSING_TOOLS" ]; then
    pass "All required tools are available: $REQUIRED_TOOLS"
else
    fail "Missing tools:$MISSING_TOOLS"
fi

# Test 6: XcodeGen is available
if command -v xcodegen &>/dev/null; then
    pass "XcodeGen is available"
else
    warn "XcodeGen not found (needed for project generation)"
fi

# Test 7: project.yml exists for macOS
if [ -f "macos/project.yml" ]; then
    pass "macos/project.yml exists"
else
    fail "macos/project.yml not found"
fi

# Test 8: Script references correct bundle ID
if grep -q "dev.910labs.voice-code-desktop" scripts/publish-macos-dmg.sh; then
    pass "Script uses correct bundle ID"
else
    fail "Script doesn't reference correct bundle ID"
fi

# Test 9: Script references correct team ID
if grep -q "REDACTED_TEAM_ID" scripts/publish-macos-dmg.sh; then
    pass "Script uses correct team ID"
else
    fail "Script doesn't reference correct team ID"
fi

# Test 10: Makefile has macOS distribution targets
MACOS_TARGETS="macos-publish macos-archive macos-dmg macos-notarize macos-staple macos-verify"
MISSING_TARGETS=""
for target in $MACOS_TARGETS; do
    if ! grep -q "^$target:" Makefile; then
        MISSING_TARGETS="$MISSING_TARGETS $target"
    fi
done

if [ -z "$MISSING_TARGETS" ]; then
    pass "Makefile has all macOS distribution targets"
else
    fail "Makefile missing targets:$MISSING_TARGETS"
fi

# Test 11: Check for Developer ID Application certificate (optional - may not be on all machines)
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    pass "Developer ID Application certificate found in keychain"
else
    warn "Developer ID Application certificate not found (needed for signing)"
fi

# Test 12: Check notarytool is available
if xcrun notarytool --version &>/dev/null; then
    pass "notarytool is available via xcrun"
else
    fail "notarytool not available (part of Xcode command line tools)"
fi

# Test 13: Check stapler is available
if xcrun stapler --version &>/dev/null 2>&1 || xcrun stapler 2>&1 | grep -q "stapler"; then
    pass "stapler is available via xcrun"
else
    fail "stapler not available (part of Xcode command line tools)"
fi

# Summary
echo ""
echo "================================"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
echo "================================"

if [ $TESTS_FAILED -gt 0 ]; then
    exit 1
fi
