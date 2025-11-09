#!/usr/bin/env python3
"""
PreToolUse hook: Block xcodebuild commands, redirect to Makefile
Keeps messages concise to minimize context window usage
"""

import json
import sys
import re
import shlex

data = json.load(sys.stdin)
command = data.get("tool_input", {}).get("command", "")

# Parse the command to find what's actually being executed
# We want to block direct execution of xcodebuild, but allow:
# - Mentions in commit messages, comments, echo statements
# - Adding them to Makefiles
# - Documentation

# Split by && and || to get individual commands
commands = re.split(r'\s*(?:&&|\|\||;)\s*', command)

blocked = False
for cmd in commands:
    # Strip leading whitespace and get the first token (the actual command)
    cmd = cmd.strip()
    if not cmd:
        continue

    # Skip if this is a git command (messages can contain anything)
    if cmd.startswith('git '):
        continue

    # Skip if this is echo, cat, or other output commands
    if re.match(r'^(echo|cat|printf)\s', cmd):
        continue

    # Now check if the actual executable being invoked is blocked
    # Extract first word (the command name)
    try:
        tokens = shlex.split(cmd)
        if tokens:
            executable = tokens[0]
            # Check if executable itself is blocked
            if executable in ['xcodebuild', 'agvtool']:
                blocked = True
                break
            # For xcrun, check if it's invoking blocked subcommands
            if executable == 'xcrun' and len(tokens) > 1:
                subcommand = tokens[1]
                if subcommand in ['xcodebuild', 'simctl', 'agvtool']:
                    blocked = True
                    break
    except ValueError:
        # shlex.split can fail on unclosed quotes - fall back to simple check
        if re.match(r'^\s*(xcodebuild|agvtool|xcrun\s+(simctl|xcodebuild|agvtool))\s', cmd):
            blocked = True
            break

if blocked:
    print("Use 'make help' for available targets. Add new targets to Makefile if needed.",
          file=sys.stderr)
    sys.exit(2)

sys.exit(0)
