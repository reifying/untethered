#!/usr/bin/env python3
"""
PreToolUse hook: Block xcodebuild commands, redirect to Makefile
Keeps messages concise to minimize context window usage
"""

import json
import sys
import re

data = json.load(sys.stdin)
command = data.get("tool_input", {}).get("command", "")

# Block xcodebuild and related Xcode CLI tools
if re.search(r'\b(xcodebuild|xcrun\s+simctl|agvtool)\b', command):
    print("Use 'make help' for available targets. Add new targets to Makefile if needed.",
          file=sys.stderr)
    sys.exit(2)

sys.exit(0)
