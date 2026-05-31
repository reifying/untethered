#!/usr/bin/env bash
# Unit tests for the `recipe` subcommand of scripts/tmux-agent.
#
# Self-contained: sources tmux-agent (main is guarded so it won't run),
# stubs `curl` and the API-key file, and points VC_BACKEND_DIR at a
# sandbox config.edn. No running backend is required.
#
# Run: bash scripts/test-tmux-agent.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_AGENT="$SCRIPT_DIR/tmux-agent"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/backend/resources"
printf '{:server {:port 9123\n          :host "0.0.0.0"}}\n' > "$TMP/backend/resources/config.edn"
printf 'secret-key\n' > "$TMP/apikey"

# tmux-agent derives VC_BACKEND_DIR="$VC_PROJECT_DIR/backend" on source, so
# point VC_PROJECT_DIR at the sandbox rather than VC_BACKEND_DIR directly.
export VC_PROJECT_DIR="$TMP"
export VC_API_KEY_FILE="$TMP/apikey"

# shellcheck source=/dev/null
source "$TMUX_AGENT"
set +eu  # relax errexit/nounset for the harness itself

# --- stub curl: capture each arg on its own line into CURL_OUT ----------
CURL_OUT=""
curl() {
  CURL_OUT=""
  local a
  for a in "$@"; do CURL_OUT+="$a"$'\n'; done
}

PASS=0; FAIL=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc"
    echo "  expected: [$expected]"
    echo "  actual:   [$actual]"
  fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc"
    echo "  expected to contain: [$needle]"
    echo "  in:"
    echo "$haystack" | sed 's/^/    /'
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc"
    echo "  did NOT expect: [$needle]"
    echo "  in: [$haystack]"
  fi
}

# --- _read_backend_port -------------------------------------------------
assert_eq "port read from config.edn" "9123" "$(_read_backend_port)"
assert_eq "port falls back to VC_BACKEND_PORT" "7000" \
  "$(export VC_BACKEND_DIR=/nonexistent VC_BACKEND_PORT=7000; _read_backend_port)"
assert_eq "port falls back to 8080" "8080" \
  "$(export VC_BACKEND_DIR=/nonexistent VC_BACKEND_PORT=; _read_backend_port)"

# --- _read_api_key ------------------------------------------------------
assert_eq "api key read from VC_API_KEY_FILE" "secret-key" "$(_read_api_key)"

# --- _recipe_start_body -------------------------------------------------
assert_eq "body: only recipe_id" \
  '{"recipe_id": "rid"}' \
  "$(_recipe_start_body "rid" "" "" "" "")"
assert_eq "body: recipe_id + workdir" \
  '{"recipe_id": "rid", "working_directory": "/wd"}' \
  "$(_recipe_start_body "rid" "/wd" "" "" "")"
assert_eq "body: all fields" \
  '{"recipe_id": "rid", "working_directory": "/wd", "session_id": "sess", "provider": "claude", "context": "ctx"}' \
  "$(_recipe_start_body "rid" "/wd" "sess" "claude" "ctx")"

# context with embedded quotes/newline round-trips through valid JSON
tricky=$'he said "hi"\nline2'
body="$(_recipe_start_body "rid" "/wd" "" "" "$tricky")"
roundtrip="$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["context"])')"
assert_eq "body: tricky context round-trips" "$tricky" "$roundtrip"

# --- cmd_recipe_start ---------------------------------------------------
cmd_recipe_start "implement-and-review-all" -d /tmp/proj
assert_contains "start: POST to /start URL" \
  "http://localhost:9123/api/recipes/start" "$CURL_OUT"
assert_contains "start: POST method" "POST" "$CURL_OUT"
assert_contains "start: JSON content-type header" \
  "Content-Type: application/json" "$CURL_OUT"
assert_contains "start: bearer auth header" \
  "Authorization: Bearer secret-key" "$CURL_OUT"
assert_contains "start: -d body has recipe_id" \
  '"recipe_id": "implement-and-review-all"' "$CURL_OUT"
assert_contains "start: -d flag sets working_directory" \
  '"working_directory": "/tmp/proj"' "$CURL_OUT"

# default workdir = pwd for a NEW session (no --session-id, no -d)
cmd_recipe_start "review-and-commit"
assert_contains "start: default workdir is pwd for new session" \
  "\"working_directory\": \"$(pwd)\"" "$CURL_OUT"

# resuming an existing session (--session-id) without -d omits
# working_directory so the backend falls back to session metadata
cmd_recipe_start "break-down-tasks" --session-id resume-uuid
assert_not_contains "start: no working_directory on resume without -d" \
  '"working_directory"' "$CURL_OUT"
assert_contains "start: session_id present on resume" \
  '"session_id": "resume-uuid"' "$CURL_OUT"

# explicit -d wins even when resuming an existing session
cmd_recipe_start "break-down-tasks" --session-id resume-uuid -d /explicit/dir
assert_contains "start: explicit -d overrides on resume" \
  '"working_directory": "/explicit/dir"' "$CURL_OUT"

# --session-id / --provider / --context
cmd_recipe_start "break-down-tasks" --session-id abc-123 --provider codex --context "hello world"
assert_contains "start: session_id passed" '"session_id": "abc-123"' "$CURL_OUT"
assert_contains "start: provider passed" '"provider": "codex"' "$CURL_OUT"
assert_contains "start: context passed" '"context": "hello world"' "$CURL_OUT"

# --context-file reads file content
ctxfile="$TMP/brief.md"
printf 'multi\nline "brief"\n' > "$ctxfile"
cmd_recipe_start "document-design" -d /p --context-file "$ctxfile"
assert_contains "start: context-file content escaped into body" \
  'multi\nline \"brief\"' "$CURL_OUT"

# omitted optionals are absent from the body
cmd_recipe_start "rebase" -d /p
assert_not_contains "start: no session_id when omitted" '"session_id"' "$CURL_OUT"
assert_not_contains "start: no provider when omitted" '"provider"' "$CURL_OUT"
assert_not_contains "start: no context when omitted" '"context"' "$CURL_OUT"

# --- cmd_recipe_list ----------------------------------------------------
cmd_recipe_list
assert_contains "list: GET /api/recipes URL" \
  "http://localhost:9123/api/recipes" "$CURL_OUT"
assert_contains "list: bearer auth header" \
  "Authorization: Bearer secret-key" "$CURL_OUT"
assert_not_contains "list: not a POST" "POST" "$CURL_OUT"

# --- cmd_recipe_status --------------------------------------------------
cmd_recipe_status "sess-xyz"
assert_contains "status: GET status URL with session id" \
  "http://localhost:9123/api/recipes/status/sess-xyz" "$CURL_OUT"
assert_contains "status: bearer auth header" \
  "Authorization: Bearer secret-key" "$CURL_OUT"

# status without a session_id errors (non-zero), does not curl
out="$( cmd_recipe_status 2>&1 )"; rc=$?
assert_eq "status: missing session_id exits non-zero" "1" "$rc"
assert_contains "status: missing session_id reports required" "session_id required" "$out"

# --- dispatch & usage ---------------------------------------------------
# `recipe` with no subcommand prints usage and exits non-zero
out="$( cmd_recipe 2>&1 )"; rc=$?
assert_eq "recipe (no subcommand) exits non-zero" "1" "$rc"
assert_contains "recipe (no subcommand) shows usage" "vc-agent recipe <command>" "$out"

# unknown recipe subcommand errors + usage, non-zero
out="$( cmd_recipe bogus 2>&1 )"; rc=$?
assert_eq "recipe bogus exits non-zero" "1" "$rc"
assert_contains "recipe bogus reports unknown" "Unknown recipe command: bogus" "$out"

# top-level usage lists recipe
out="$( usage 2>&1 )"; rc=$?
assert_contains "top-level usage lists recipe" "recipe <command>" "$out"

# --- summary ------------------------------------------------------------
echo ""
echo "PASS: $PASS   FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "All tmux-agent recipe tests passed."
