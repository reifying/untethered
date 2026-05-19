#!/bin/bash
#
# probe-compact-prefix.sh — Resolve §1 OPEN item: does `claude --compact` rewrite
# the JSONL prefix or pure-tail-append?
#
# Recipe (per ~/assist/notes/voice-code-sync-kafka-redesign-2026-05-10.md#§1):
#   1. Snapshot pre-length + pre-sha of target JSONL.
#   2. Operator runs `claude --compact` against the matching session.
#   3. Compute post-length, plus post-prefix-sha = sha256 of first pre-length bytes.
#   4. Verdict:
#      post-length >  pre-length AND post-prefix-sha == pre-sha → TAIL-APPEND
#      post-prefix-sha != pre-sha                               → PREFIX-REWRITE
#      post-length <  pre-length                                → TRUNCATE
#
# Refuses to run if the file isn't quiescent (mtime stable for ~3s).
# Never modifies the JSONL — pure observation.

set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage:
  $0 <jsonl-path>            # interactive probe (snapshot, pause, compare)
  $0 --self-test             # synthesize all three verdicts on a temp file
EOF
  exit 2
}

sha256_first_n() {
  # sha256 of the first $2 bytes of file $1 — uses dd to avoid loading the whole file
  local file="$1" n="$2"
  dd if="$file" bs=1 count="$n" status=none 2>/dev/null | shasum -a 256 | awk '{print $1}'
}

sha256_full() {
  shasum -a 256 "$1" | awk '{print $1}'
}

file_length() {
  stat -f%z "$1"
}

file_mtime() {
  stat -f%m "$1"
}

wait_for_quiescence() {
  local file="$1"
  local prev=$(file_mtime "$file")
  local stable_for=0
  local required=3
  echo "Waiting for $file to be quiescent (mtime stable for ${required}s)..." >&2
  while [ $stable_for -lt $required ]; do
    sleep 1
    local cur=$(file_mtime "$file")
    if [ "$cur" = "$prev" ]; then
      stable_for=$((stable_for + 1))
    else
      stable_for=0
      prev="$cur"
    fi
  done
  echo "File quiescent." >&2
}

verdict() {
  # Args: pre_length post_length pre_sha post_prefix_sha
  local pre_len="$1" post_len="$2" pre_sha="$3" post_prefix_sha="$4"
  if [ "$post_len" -lt "$pre_len" ]; then
    echo "TRUNCATE"
  elif [ "$pre_sha" != "$post_prefix_sha" ]; then
    echo "PREFIX-REWRITE"
  elif [ "$post_len" -gt "$pre_len" ]; then
    echo "TAIL-APPEND"
  else
    echo "UNCHANGED"
  fi
}

run_probe() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "error: $file does not exist or is not a regular file" >&2
    exit 1
  fi

  wait_for_quiescence "$file"

  local pre_len=$(file_length "$file")
  local pre_sha=$(sha256_full "$file")
  echo
  echo "=== PRE-COMPACT SNAPSHOT ==="
  echo "  file:       $file"
  echo "  pre-length: $pre_len bytes"
  echo "  pre-sha256: $pre_sha"
  echo
  echo "Now run \`claude --compact\` against the matching session."
  echo "Press Enter when compaction is complete..."
  read -r _

  wait_for_quiescence "$file"

  local post_len=$(file_length "$file")
  local post_prefix_sha
  if [ "$post_len" -ge "$pre_len" ]; then
    post_prefix_sha=$(sha256_first_n "$file" "$pre_len")
  else
    post_prefix_sha="(file shorter than pre-length; prefix-sha n/a)"
  fi
  local post_full_sha=$(sha256_full "$file")

  echo
  echo "=== POST-COMPACT SNAPSHOT ==="
  echo "  post-length:     $post_len bytes  (delta: $((post_len - pre_len)))"
  echo "  post-prefix-sha: $post_prefix_sha"
  echo "  post-full-sha:   $post_full_sha"
  echo
  local v=$(verdict "$pre_len" "$post_len" "$pre_sha" "$post_prefix_sha")
  echo "=== VERDICT: $v ==="
  case "$v" in
    TAIL-APPEND)
      echo "  Compact is append-only. R2 (file_replaced recovery) is corruption-only;"
      echo "  shrink-recovery branch (replication.clj:1121-1148) is defending against"
      echo "  a phantom."
      ;;
    PREFIX-REWRITE)
      echo "  Compact rewrites the prefix. R2 is the routine compact-recovery surface;"
      echo "  AC8 fires per-compact in production. Keep file-signature mismatch fast."
      ;;
    TRUNCATE)
      echo "  Post-file is strictly shorter than pre. Shrink-recovery branch fires."
      echo "  Strong PREFIX-REWRITE signal in spirit (rewrites with truncation)."
      ;;
    UNCHANGED)
      echo "  No change observed — operator may have skipped the compaction step."
      ;;
  esac
}

self_test() {
  local tmpdir
  tmpdir=$(mktemp -d -t probe-compact.XXXXXX)
  trap 'rm -rf "$tmpdir"' EXIT
  local f="$tmpdir/test.jsonl"
  local fails=0

  echo "=== SELF-TEST ==="

  # TAIL-APPEND
  printf 'aaaa' > "$f"
  local pre_len=$(file_length "$f")
  local pre_sha=$(sha256_full "$f")
  printf 'bbbb' >> "$f"
  local post_len=$(file_length "$f")
  local post_prefix_sha=$(sha256_first_n "$f" "$pre_len")
  local v=$(verdict "$pre_len" "$post_len" "$pre_sha" "$post_prefix_sha")
  if [ "$v" = "TAIL-APPEND" ]; then
    echo "  [PASS] TAIL-APPEND (pre=$pre_len, post=$post_len)"
  else
    echo "  [FAIL] TAIL-APPEND expected, got $v"
    fails=$((fails + 1))
  fi

  # PREFIX-REWRITE (same length, different content)
  printf 'aaaa' > "$f"
  pre_len=$(file_length "$f")
  pre_sha=$(sha256_full "$f")
  printf 'XXXXyyyy' > "$f"  # length grew but prefix changed
  post_len=$(file_length "$f")
  post_prefix_sha=$(sha256_first_n "$f" "$pre_len")
  v=$(verdict "$pre_len" "$post_len" "$pre_sha" "$post_prefix_sha")
  if [ "$v" = "PREFIX-REWRITE" ]; then
    echo "  [PASS] PREFIX-REWRITE (prefix sha changed)"
  else
    echo "  [FAIL] PREFIX-REWRITE expected, got $v"
    fails=$((fails + 1))
  fi

  # TRUNCATE
  printf 'aaaabbbb' > "$f"
  pre_len=$(file_length "$f")
  pre_sha=$(sha256_full "$f")
  printf 'aa' > "$f"
  post_len=$(file_length "$f")
  # post is shorter — verdict should be TRUNCATE without needing prefix-sha
  v=$(verdict "$pre_len" "$post_len" "$pre_sha" "(skipped)")
  if [ "$v" = "TRUNCATE" ]; then
    echo "  [PASS] TRUNCATE (post=$post_len < pre=$pre_len)"
  else
    echo "  [FAIL] TRUNCATE expected, got $v"
    fails=$((fails + 1))
  fi

  # UNCHANGED (control)
  printf 'aaaa' > "$f"
  pre_len=$(file_length "$f")
  pre_sha=$(sha256_full "$f")
  post_len=$pre_len
  post_prefix_sha=$pre_sha
  v=$(verdict "$pre_len" "$post_len" "$pre_sha" "$post_prefix_sha")
  if [ "$v" = "UNCHANGED" ]; then
    echo "  [PASS] UNCHANGED (control)"
  else
    echo "  [FAIL] UNCHANGED expected, got $v"
    fails=$((fails + 1))
  fi

  echo
  if [ $fails -eq 0 ]; then
    echo "All 4 self-test cases passed."
    exit 0
  else
    echo "$fails self-test case(s) failed."
    exit 1
  fi
}

case "${1:-}" in
  --self-test) self_test ;;
  -h|--help|"") usage ;;
  *) run_probe "$1" ;;
esac
