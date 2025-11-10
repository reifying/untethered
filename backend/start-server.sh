#!/bin/bash
cd "$(dirname "$0")"
nohup clojure -M -m voice-code.server > /dev/null 2>&1 &
echo $! > .backend-pid
echo "Backend server started (PID: $(cat .backend-pid))"
