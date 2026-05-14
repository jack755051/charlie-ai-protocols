#!/usr/bin/env bash
#
# test-component-fast-dry-run.sh — P1b slice 6b-2 gate.
#
# Verifies `cap workflow run --dry-run --cli claude component-fast`
# walks the full plan + binding path without invoking a provider
# binary. After 6b-0 (constitution allowlist) and 6b-1 (skill
# mapping) the binding is `ready`; this slice confirms the dry-run
# CLI path actually exercises that ready state with zero token
# spend, before slice 6b spends real Claude quota on threshold
# measurement.
#
# Out of scope:
#   - No real `cap workflow run` (no --dry-run flag).
#   - No measurement against the five P1a thresholds (slice 6b).
#   - No skill registry edits (slice 6b-1 already landed those).
#
# Provider isolation strategy:
#   The test sets CAP_CLAUDE_BIN to an absolute path that does not
#   exist (/tmp/cap-dry-run-should-not-execute). engine/
#   provider_adapter.py honours this override for claude binary
#   resolution. If dry-run accidentally invoked the provider, the
#   command would fail with "command not found" and exit non-zero.
#   A passing test under this env is strong evidence no provider
#   was called.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP="${REPO_ROOT}/scripts/cap-entry.sh"

[ -x "${CAP}" ] || { echo "FAIL: ${CAP} not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-fast-dry-run.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected: ${expected}"
    echo "    actual:   ${actual}"
    fail_count=$((fail_count + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    needle: ${needle}"
    fail_count=$((fail_count + 1))
  fi
}

# ── Run dry-run once under a sandboxed CAP_HOME + nonsense provider bin ─
NONEXIST_CLAUDE="/tmp/cap-dry-run-should-not-execute-$$"
[ ! -e "${NONEXIST_CLAUDE}" ] || { echo "FAIL: sentinel claude bin path exists"; exit 1; }

echo "Case 1: dry-run completes exit 0 with sandboxed CAP_HOME"
DRY_OUT="$(
  CAP_HOME="${SANDBOX}/cap" \
  CAP_CLAUDE_BIN="${NONEXIST_CLAUDE}" \
  bash "${CAP}" workflow run --dry-run --cli claude component-fast \
    "dry-run sanity test prompt — must not invoke a provider" 2>&1
)"
DRY_RC=$?
assert_eq        "dry-run exit 0"                                "0"                                          "${DRY_RC}"
assert_contains "dry-run header names the workflow"              "${DRY_OUT}"  "WORKFLOW DRY RUN"
assert_contains "dry-run identifies Component Fast Path"          "${DRY_OUT}"  "Component Fast Path"
assert_contains "dry-run end-of-run guard message present"        "${DRY_OUT}"  "Dry run only — no step was executed"

# ── Case 2: every workflow step id appears in dry-run output ─────────
echo ""
echo "Case 2: every workflow step id appears in dry-run output"
for step_id in resolve_inputs render_skeleton deterministic_audit smoke_runtime compact_review fix_or_polish archive; do
  assert_contains "dry-run lists ${step_id}"  "${DRY_OUT}"  "${step_id}"
done

# ── Case 3: dry-run binding block reports the ready state ────────────
#
# The dry-run header includes a Binding block plus per-step lines.
# After 6b-0 (constitution) and 6b-1 (skill registry) the expected
# state is binding_status=ready / resolved=7 / fallback=0 — same
# truth the binding-sanity test pins, here observed via the run
# entry point.
echo ""
echo "Case 3: dry-run binding block matches the 6b-1 ready state"
assert_contains "dry-run binding line shows ready"               "${DRY_OUT}"  "Binding: ready"
assert_contains "dry-run resolves resolve_inputs to shell"        "${DRY_OUT}"  "resolve_inputs: resolved -> builtin-shell"
assert_contains "dry-run resolves render_skeleton to shell"       "${DRY_OUT}"  "render_skeleton: resolved -> builtin-shell"
assert_contains "dry-run resolves deterministic_audit to shell"   "${DRY_OUT}"  "deterministic_audit: resolved -> builtin-shell"
assert_contains "dry-run resolves smoke_runtime to shell"         "${DRY_OUT}"  "smoke_runtime: resolved -> builtin-shell"
assert_contains "dry-run resolves compact_review to watcher"      "${DRY_OUT}"  "compact_review: resolved -> builtin-watcher"
assert_contains "dry-run resolves fix_or_polish to backend"       "${DRY_OUT}"  "fix_or_polish: resolved -> builtin-backend"
assert_contains "dry-run resolves archive to shell"               "${DRY_OUT}"  "archive: resolved -> builtin-shell"

# ── Case 4: nonsense CAP_CLAUDE_BIN proves no provider invocation ────
#
# The previous Cases already ran dry-run with CAP_CLAUDE_BIN pointing
# at a path that does not exist. The fact that Case 1 produced exit 0
# is itself the proof. This case adds two belt-and-suspenders checks:
#   - the dry-run output contains no provider-invocation telltales
#   - the sentinel binary path still does not exist (i.e. nothing
#     surreptitiously created it during the run).
echo ""
echo "Case 4: dry-run did not shell out to the claude binary"
provider_hits="$(grep -iE 'invoking claude|spawned claude|claude exited|api.anthropic' <<<"${DRY_OUT}" || true)"
assert_eq "no claude invocation telltale in output" "" "${provider_hits}"
if [ -e "${NONEXIST_CLAUDE}" ]; then
  echo "  FAIL: sentinel claude path was created during dry-run: ${NONEXIST_CLAUDE}"
  fail_count=$((fail_count + 1))
else
  echo "  PASS: sentinel claude path absent after dry-run"
  pass_count=$((pass_count + 1))
fi

# ── Case 5: dry-run did not write provider session artifacts ─────────
#
# `cap workflow run` (non-dry) creates per-step provider session
# traces under <cap_home>/projects/<id>/reports/workflows/<wf>/run_*/
# and writes the agent-sessions ledger + prompt snapshots. dry-run
# should bind + plan but skip every executor.
#
# The project-store init writes EMPTY scaffold dirs (sessions/ /
# traces/ / cache/ / drafts/ / workspace/ / logs/ / bindings/ /
# constitutions/ / compiled-workflows/ / handoffs/ / reports/ /
# reports/workflows/). Those are not provider artifacts and the
# test must not flag them. The real signal is the absence of any
# run_* directory, agent-sessions.json, runtime-state.json, or
# prompt-snapshot file.
echo ""
echo "Case 5: no run_dir / session ledger / prompt artifacts under sandbox"

run_dir_hits=0
if [ -d "${SANDBOX}/cap" ]; then
  while IFS= read -r hit; do
    [ -n "${hit}" ] || continue
    run_dir_hits=$((run_dir_hits + 1))
  done < <(find "${SANDBOX}/cap" -type d -name 'run_*' 2>/dev/null)
fi
assert_eq "no run_* directory under sandbox" "0" "${run_dir_hits}"

# Per-run ledger / state files are written by the AI executor only
# AFTER a real provider returns.
for ledger_file in agent-sessions.json runtime-state.json workflow.log; do
  hits=0
  if [ -d "${SANDBOX}/cap" ]; then
    while IFS= read -r hit; do
      [ -n "${hit}" ] || continue
      hits=$((hits + 1))
    done < <(find "${SANDBOX}/cap" -type f -name "${ledger_file}" 2>/dev/null)
  fi
  assert_eq "no ${ledger_file} written" "0" "${hits}"
done

# sessions/ and traces/ are project-store scaffold; they exist but
# must stay empty.
for scaffold in sessions traces prompts; do
  file_count=0
  if [ -d "${SANDBOX}/cap" ]; then
    while IFS= read -r hit; do
      [ -n "${hit}" ] || continue
      file_count=$((file_count + 1))
    done < <(find "${SANDBOX}/cap" -path "*/projects/*/${scaffold}/*" -type f 2>/dev/null)
  fi
  assert_eq "no files inside scaffold ${scaffold}/" "0" "${file_count}"
done

echo ""
total=$((pass_count + fail_count))
echo "component-fast-dry-run: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
