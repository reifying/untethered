#!/bin/bash
# Start the voice-code backend server
# This script checks for port conflicts before starting

cd "$(dirname "$0")"

# Read port from config.edn using Clojure (structured parsing), defaulting to 8080
PORT=$(clojure -M -e '(-> (try (slurp "resources/config.edn") (catch Exception _ "{}"))
                          clojure.edn/read-string
                          (get-in [:server :port] 8080)
                          println)' 2>/dev/null)
PORT=${PORT:-8080}

# Check if port is already in use
if lsof -i :$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: Port $PORT is already in use."
    echo ""
    echo "To see what's using the port:"
    echo "  lsof -i :$PORT"
    echo ""
    echo "To stop all backend servers:"
    echo "  make backend-stop-all"
    exit 1
fi

# Raise file descriptor limit (Claude CLI requires high limit)
ulimit -n 2147483646

# Start the server in background
nohup clojure -M -m voice-code.server > server.out 2>&1 &
SERVER_PID=$!
echo $SERVER_PID > .backend-pid

# Wait briefly and verify the server is still running
sleep 2

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "ERROR: Backend server failed to start."
    echo ""
    echo "Check server.out for details:"
    echo "  tail -50 backend/server.out"
    rm -f .backend-pid
    exit 1
fi

echo "Backend server started on port $PORT (PID: $SERVER_PID)"
