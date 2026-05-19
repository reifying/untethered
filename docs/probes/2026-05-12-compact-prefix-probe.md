# Compact-prefix probe — §1 OPEN item

**Beads task:** `tmux-untethered-398.14`
**Design reference:** `~/assist/notes/voice-code-sync-kafka-redesign-2026-05-10.md#§1` and `#§6 R2`
**Probe script:** `scripts/probe-compact-prefix.sh`

## Question

Does `claude --compact` rewrite the JSONL prefix (PREFIX-REWRITE — R2 / `file_replaced` becomes a routine recovery surface, fires per-compact in production), or pure-tail-append (TAIL-APPEND — the existing shrink-recovery branch at `replication.clj:1121-1148` is defending against a phantom and can be deleted)?

A naive sha256 of the whole file can't distinguish the two — both change the hash. The recipe is byte-prefix comparison: snapshot `pre-length` + `pre-sha` before compact, then post-compact compute the sha256 of the first `pre-length` bytes and compare against `pre-sha`.

## Corroborating production-log check

Ran `grep -c 'shrank\|shrunk' .../backend/server.out` across every live `voice-code-*` worktree on this machine:

| Worktree                        |  Lines | Bytes  | Shrink-recovery firings |
| ------------------------------- | -----: | -----: | ----------------------: |
| voice-code                      | 48,506 |  ~7.6M |                       0 |
| voice-code-connectivity         | 67,137 |  ~9.6M |                       0 |
| voice-code-github-copilot       | 68,857 | ~10.1M |                       0 |
| voice-code-hooks                |     47 |   3.5K |                       0 |
| voice-code-react-native         | 14,297 |  ~2.2M |                       0 |
| voice-code-tmux-untethered      | 43,277 |  ~6.9M |                       0 |
| **total**                       | **242,121** | **~36MB** | **0** |

Source log message: `replication.clj:1145` — `"JSONL file shrank below tracked cursor; resetting to 0"` (also a sibling Copilot version at `replication.clj:2023`).

**Empirical reading:** across ~242k lines of mixed-provider production traffic, the shrink-recovery branch has never fired. That is strong negative evidence against PREFIX-REWRITE *with truncation* (the TRUNCATE verdict in the probe). It does NOT distinguish TAIL-APPEND from PREFIX-REWRITE-without-truncation (a compact that rewrites the prefix to a length ≥ the old length).

## Probe results per session

These rows are filled in by the operator running `scripts/probe-compact-prefix.sh <jsonl-path>`. Each row corresponds to one real Claude session — pick sessions of meaningfully different sizes per the task spec.

| # | Session | Pre-length | Pre-sha (head) | Post-length | Post-prefix-sha (head) | Verdict |
| - | ------- | ---------: | -------------- | ----------: | ---------------------- | ------- |
| 1 | _TBD_   | _TBD_      | _TBD_          | _TBD_       | _TBD_                  | _TBD_   |
| 2 | _TBD_   | _TBD_      | _TBD_          | _TBD_       | _TBD_                  | _TBD_   |

## Probe self-test (script smoke)

`scripts/probe-compact-prefix.sh --self-test` synthesizes each of the four verdicts on a temp file and asserts `verdict()` returns the right label. Run on 2026-05-12 against the committed script — all 4 cases (TAIL-APPEND / PREFIX-REWRITE / TRUNCATE / UNCHANGED control) passed.

## Recommendation

_Filled in once probe rows are complete. The expected resolutions:_

- **All TAIL-APPEND** → shrink-recovery branch at `replication.clj:1121-1148` (and the Copilot sibling at `:2008-2023`) is dead code on the v0.5.0 path. **Action:** file a follow-up `bd create` (out-of-cycle, not under epic `tmux-untethered-398`) to delete it. Update T2 / T5 / T10 design notes to drop the shrink-recovery requirement from their scope. R2 / `file_replaced` becomes a corruption-only surface — keep it for defense-in-depth but de-prioritise its perf budget.
- **Any PREFIX-REWRITE** → compact is the routine R2 trigger. **Action:** keep the shrink-recovery branch; ensure T9 (`file_signature` mismatch handling) and T12 (iOS `file_replaced` branch) are budgeted as hot paths, not corruption-rare paths. The "Keep R2 hot" decision propagates to AC8 testing — expect file_replaced to fire per-compact in production telemetry.
- **Mixed** → both paths are reachable in practice. Keep R2 hot AND keep shrink-recovery alive.

## Follow-up ticket

_If the recommendation is "delete shrink-recovery as dead code," the bd-create line goes here. Format suggestion:_

```
bd create --title="Delete dead shrink-recovery branch in replication.clj (post-§1 probe)" \
          --description="Probe results in docs/probes/2026-05-12-compact-prefix-probe.md show TAIL-APPEND for all tested sessions; the production-log corroborating check (0 firings across ~242k lines) agrees. The branches at replication.clj:1121-1148 and :2008-2023 are dead code. Delete them and their log messages." \
          --type=task --priority=3
```
