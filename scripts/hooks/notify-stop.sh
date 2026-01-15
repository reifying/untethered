#!/bin/bash
# Notify voice-code backend of Claude session activity
#
# This script is called by Claude Code's Stop hook when a conversation turn completes.
# It notifies the voice-code backend about external sessions (sessions started from
# terminal, not from iOS) so they can appear in the iOS session list.
#
# Only uses public hook payload fields: session_id, cwd
# Does NOT read transcript_path (internal implementation detail)
#
# Installation:
# 1. Copy this script to ~/.voice-code/hooks/notify-stop.sh
# 2. Make it executable: chmod +x ~/.voice-code/hooks/notify-stop.sh
# 3. Add to ~/.claude/settings.json:
#    {
#      "hooks": {
#        "Stop": [{
#          "hooks": [{
#            "type": "command",
#            "command": "~/.voice-code/hooks/notify-stop.sh"
#          }]
#        }]
#      }
#    }

# Read JSON payload from stdin
input=$(cat)

# Extract fields using jq
session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')

# Validate required fields
if [ -z "$session_id" ] || [ -z "$cwd" ]; then
    # Silent exit - missing fields are not an error for the hook
    exit 0
fi

# Notify backend - fail silently if backend not running
# Uses VOICE_CODE_PORT environment variable, defaults to 7865
curl -s -X POST "http://localhost:${VOICE_CODE_PORT:-7865}/api/hook/stop" \
    -H "Content-Type: application/json" \
    -d "{\"session_id\": \"$session_id\", \"cwd\": \"$cwd\"}" \
    2>/dev/null || true

# Always exit successfully - hook errors shouldn't disrupt Claude
exit 0
