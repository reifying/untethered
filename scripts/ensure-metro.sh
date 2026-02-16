#!/bin/bash
# Ensure Metro bundler is running on port 8081.
# Idempotent: if Metro is already healthy, exits immediately.
# Usage: ./scripts/ensure-metro.sh [frontend-dir]

set -e

METRO_PORT=8081
RN_DIR="${1:-$(cd "$(dirname "$0")/../frontend" && pwd)}"
PID_FILE="$RN_DIR/.metro-pid"
LOG_FILE="$RN_DIR/.metro.log"
HEALTH_URL="http://localhost:$METRO_PORT/status"
STARTUP_TIMEOUT=30  # seconds

# Check if Metro is already running and healthy
if curl -s --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
    echo "Metro already running on port $METRO_PORT"
    exit 0
fi

# Port occupied by something other than Metro
if lsof -i :$METRO_PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: Port $METRO_PORT is in use but not responding as Metro."
    echo ""
    echo "To see what's using the port:"
    echo "  lsof -i :$METRO_PORT"
    echo ""
    echo "To kill whatever is on that port:"
    echo "  lsof -ti :$METRO_PORT | xargs kill"
    exit 1
fi

# Clean up stale PID file
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ! kill -0 "$OLD_PID" 2>/dev/null; then
        rm -f "$PID_FILE"
    fi
fi

# Start Metro
echo "Starting Metro bundler..."
cd "$RN_DIR"
npx react-native start --port "$METRO_PORT" > "$LOG_FILE" 2>&1 &
METRO_PID=$!
echo "$METRO_PID" > "$PID_FILE"

# Wait for health check
elapsed=0
while [ $elapsed -lt $STARTUP_TIMEOUT ]; do
    if curl -s --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
        echo "Metro bundler running on port $METRO_PORT (PID: $METRO_PID)"
        exit 0
    fi

    # Check if process died
    if ! kill -0 "$METRO_PID" 2>/dev/null; then
        echo "ERROR: Metro failed to start."
        echo ""
        echo "Check log for details:"
        echo "  tail -50 $LOG_FILE"
        rm -f "$PID_FILE"
        exit 1
    fi

    sleep 1
    elapsed=$((elapsed + 1))
done

echo "ERROR: Metro did not become healthy within ${STARTUP_TIMEOUT}s."
echo ""
echo "Check log for details:"
echo "  tail -50 $LOG_FILE"
echo ""
echo "Process is still running (PID: $METRO_PID). You may want to kill it:"
echo "  kill $METRO_PID"
exit 1
