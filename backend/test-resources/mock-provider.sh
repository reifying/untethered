#!/usr/bin/env bash
# Mock provider CLI for tmux integration testing.
# Usage: mock-provider.sh <provider>
# Prints the provider-specific readiness string, writes canned JSONL to $MOCK_JSONL if set,
# then sleeps so the tmux window stays alive.

PROVIDER="${1:-claude}"

case "$PROVIDER" in
  claude)
    echo "? for shortcuts · bypass permissions"
    ;;
  copilot)
    echo "Type @ to mention a file"
    ;;
  cursor)
    echo "Press any key to continue"
    ;;
  opencode)
    echo "Ask anything about your code"
    ;;
  *)
    echo "bypass permissions"
    ;;
esac

if [ -n "$MOCK_JSONL" ]; then
  mkdir -p "$(dirname "$MOCK_JSONL")"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Test response"}],"stop_reason":"end_turn"}}' >> "$MOCK_JSONL"
fi

exec tail -f /dev/null
