#!/usr/bin/env bash
#
# verify-br-migration.sh — acceptance test for the bd (Dolt) → br (beads_rust)
# data migration (beads issue tmux-untethered-t7v.1).
#
# Asserts the post-migration invariants from docs/design/beads-rust-migration.md
# §4 (Verification Strategy) and the t7v.1 task checklist:
#   - br is installed at v0.2.11+
#   - all non-closed issues from the three source branches + the migration epic
#     are present in br
#   - the 35 beads-sync backlog issues carry the needs-triage label
#   - the xd0 share-logs epic dependency graph is reconstructed
#   - Dolt artifacts are removed and .beads/issues.jsonl is valid
#
# Run from the repo root. Exits non-zero on the first failed assertion.
#
# NOTE: This is a ONE-TIME migration acceptance check, not a durable unit test.
# The expected counts (264 total issues, 35 needs-triage) are the post-migration
# snapshot and will drift once the needs-triage backlog is triaged or new issues
# are created. Treat a failure here as "re-confirm the migration", not "the code
# regressed". Safe to delete once the migration is committed and confirmed.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# 1. br installed at v0.2.11+
command -v br >/dev/null 2>&1 || fail "br is not installed / not on PATH"
ver="$(br version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$ver" ] || fail "could not parse br version"
printf '%s\n0.2.11\n' "$ver" | sort -V | tail -1 | grep -qx "$ver" \
  || fail "br version $ver < 0.2.11"
pass "br installed (v$ver)"

# 2. issue counts match the consolidated import (264 total; 51 non-closed)
total="$(br stats 2>/dev/null | awk -F: '/Total Issues:/{gsub(/ /,"",$2);print $2}')"
[ "$total" = "264" ] || fail "expected 264 total issues, got '$total'"
pass "br stats: 264 total issues"

# 3. migration epic + 9 children imported (exist only in the live DB, no branch JSONL)
for id in t7v t7v.1 t7v.2 t7v.3 t7v.4 t7v.5 t7v.6 t7v.7 t7v.8 t7v.9; do
  br show "tmux-untethered-$id" >/dev/null 2>&1 \
    || fail "migration issue tmux-untethered-$id missing after import"
done
pass "migration epic + 9 children present"

# 4. exactly the 35 beads-sync issues carry needs-triage
triage_count="$(br list --label needs-triage --json 2>/dev/null \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["issues"]))')"
[ "$triage_count" = "35" ] || fail "expected 35 needs-triage issues, got '$triage_count'"
pass "35 issues labeled needs-triage"

# 5. xd0 epic depends on all 6 children
# br dep list --json returns a flat array of dependency edges.
xd0_deps="$(br dep list tmux-untethered-xd0 --json 2>/dev/null \
  | python3 -c '
import json,sys
deps=json.load(sys.stdin)
if isinstance(deps,dict): deps=deps.get("dependencies",[])
print(",".join(sorted(x["depends_on_id"].replace("tmux-untethered-","") for x in deps)))')"
[ "$xd0_deps" = "11d,19f,7hp,7zo,etr,kmn" ] \
  || fail "xd0 deps mismatch: got '$xd0_deps' (want 11d,19f,7hp,7zo,etr,kmn)"
pass "xd0 epic depends on all 6 children"

# 6. blocked chain: xd0 is blocked, 7zo (closed) is not a counted blocker
# Capture first (grep -q would SIGPIPE br mid-write under pipefail).
blocked_out="$(br blocked 2>/dev/null)"
echo "$blocked_out" | grep -q "tmux-untethered-xd0" \
  || fail "br blocked does not show tmux-untethered-xd0"
pass "br blocked shows xd0"

# 7. Dolt artifacts removed
for art in embeddeddolt backup export-state.json README.md interactions.jsonl; do
  [ ! -e ".beads/$art" ] || fail ".beads/$art still exists (Dolt artifact)"
done
pass "Dolt artifacts removed"

# 8. issues.jsonl is valid JSON AND a canonical, round-trip-stable br export.
#    A non-canonical file (e.g. raw bd-format merge input) imports fine but gets
#    rewritten by the next br mutation, producing a spurious diff. br's own
#    "Dirty issues: 0 / In sync" status does NOT detect this, so the only
#    reliable check is flush-and-compare: a forced flush of the canonical form
#    must leave the file byte-identical. We snapshot first and restore on
#    mismatch so this check never leaves a mutated working tree.
python3 -c '
import json
n=sum(1 for l in open(".beads/issues.jsonl") if l.strip() and json.loads(l))
assert n==264, f"expected 264 JSONL lines, got {n}"
' || fail ".beads/issues.jsonl is not 264 valid JSON lines"

snapshot="$(mktemp)"
cp .beads/issues.jsonl "$snapshot"
if ! br sync --flush-only --force >/dev/null 2>&1; then
  rm -f "$snapshot"; fail "br sync --flush-only --force failed"
fi
if ! diff -q "$snapshot" .beads/issues.jsonl >/dev/null 2>&1; then
  cp "$snapshot" .beads/issues.jsonl   # restore: leave the tree as we found it
  rm -f "$snapshot"
  fail ".beads/issues.jsonl is not canonical — a forced br flush rewrote it"
fi
rm -f "$snapshot"
pass ".beads/issues.jsonl valid (264 lines) and canonical (flush-stable)"

echo
echo "All migration acceptance checks passed."
