#!/usr/bin/env bash
#
# test-replay-verifier.sh — H1 #3 focused test for engine/replay_verifier.py.
#
# Cases:
#   1. replayable verdict when stored == current baseline
#   2. drifted_compatible when dir_hash differs but used files unchanged
#   3. drifted_incompatible when a used prompt file changed
#   4. drifted_incompatible when a used prompt file was removed
#   5. unverifiable when envelope has no agent_skills_baseline
#   6. not_found when run dir is missing
#   7. write_verdict + snapshot mirror created via --write flag
#   8. CLI exit code matches verdict enum (replayable=0, incompatible=4,
#      not_found=2)
#   9. Each produced envelope passes schemas/replay-verdict.schema.yaml
#
# Sandbox: every case builds an isolated agent-skills/ + run_dir tree
# and injects deterministic baselines via the verify_run kwargs so the
# test never touches the real cap-protocols repo state.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VERIFIER_PY="${REPO_ROOT}/engine/replay_verifier.py"
SCHEMA_PATH="${REPO_ROOT}/schemas/replay-verdict.schema.yaml"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${VERIFIER_PY}" ] || { echo "FAIL: replay_verifier.py missing"; exit 1; }
[ -f "${SCHEMA_PATH}" ] || { echo "FAIL: schema missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-replay-verifier-test.XXXXXX)"
SANDBOX="$(cd "${SANDBOX}" && pwd -P)"
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

# ── Helpers ─────────────────────────────────────────────────────────

# build_run_dir <name> <baseline_json> <sessions_json>
#   Creates ${SANDBOX}/<name>/ with an agent-sessions.json envelope
#   carrying the supplied baseline and sessions list.
build_run_dir() {
  local name="$1" baseline="$2" sessions="$3"
  local run_dir="${SANDBOX}/${name}"
  mkdir -p "${run_dir}"
  cat > "${run_dir}/agent-sessions.json" <<EOF
{
  "version": 1,
  "run_id": "${name}",
  "workflow_id": "test-workflow",
  "workflow_name": "test",
  "agent_skills_baseline": ${baseline},
  "sessions": ${sessions}
}
EOF
  printf '%s' "${run_dir}"
}

# verify <run_dir> <current_snapshot_json> [--write]
#   Invoke the pure verify_run() with an injected current_snapshot to
#   make outcomes deterministic regardless of the real cap-protocols
#   state. Prints the verdict envelope JSON to stdout.
verify() {
  local run_dir="$1" current_json="$2" write_flag="${3:-}"
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${run_dir}" "${current_json}" "${write_flag}" <<'PY'
import json
import sys
from pathlib import Path
from datetime import datetime, timezone

sys.path.insert(0, "")
from engine import replay_verifier as rv

run_dir = Path(sys.argv[1])
current = json.loads(sys.argv[2])
write_flag = sys.argv[3]

verdict = rv.verify_run(
    run_dir,
    current_snapshot=current,
    verified_at=datetime(2026, 5, 7, 1, 0, 0, tzinfo=timezone.utc),
)

if write_flag == "--write":
    rv.write_verdict(run_dir, verdict)
    observed_full = rv._read_observed_full(run_dir)
    rv.write_snapshot_mirror(run_dir, observed_full)

print(json.dumps(verdict, ensure_ascii=False, indent=2))
PY
}

# baseline_with <dir_hash> <prompt_files_json>
baseline_with() {
  local dir_hash="$1" files="$2"
  cat <<EOF
{
  "cap_version": "v0.22.0",
  "git_commit": "abc1234",
  "git_dirty": false,
  "computed_at": "2026-05-06T00:00:00Z",
  "dir_hash": "${dir_hash}",
  "prompt_files": ${files},
  "baseline_root": "/tmp/agent-skills"
}
EOF
}

# ── Case 1: replayable ──────────────────────────────────────────────

echo "Case 1: replayable verdict"
BASELINE_OK="$(baseline_with "sha256:aaa" '{"01-supervisor-agent.md":"sha256:s1","04-frontend-agent.md":"sha256:f1"}')"
SESS_OK='[{"session_id":"s1","prompt_file":"agent-skills/01-supervisor-agent.md"},
          {"session_id":"s2","prompt_file":"agent-skills/04-frontend-agent.md"}]'
RUN1="$(build_run_dir run_001 "${BASELINE_OK}" "${SESS_OK}")"
ENV1="$(verify "${RUN1}" "${BASELINE_OK}")"
V1="$(printf '%s' "${ENV1}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['verdict'])")"
assert_eq "case1: verdict=replayable" "replayable" "${V1}"
DH1="$(printf '%s' "${ENV1}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['drift_details']['dir_hash_match'])")"
assert_eq "case1: dir_hash_match=True" "True" "${DH1}"

# ── Case 2: drifted_compatible ──────────────────────────────────────

echo ""
echo "Case 2: drifted_compatible (dir_hash differs but used files unchanged)"
BASELINE_NEW="$(baseline_with "sha256:bbb" '{"01-supervisor-agent.md":"sha256:s1","04-frontend-agent.md":"sha256:f1","strategies/lighthouse-audit.md":"sha256:added"}')"
RUN2="$(build_run_dir run_002 "${BASELINE_OK}" "${SESS_OK}")"
ENV2="$(verify "${RUN2}" "${BASELINE_NEW}")"
V2="$(printf '%s' "${ENV2}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['verdict'])")"
assert_eq "case2: verdict=drifted_compatible" "drifted_compatible" "${V2}"
DH2="$(printf '%s' "${ENV2}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['drift_details']['dir_hash_match'])")"
assert_eq "case2: dir_hash_match=False" "False" "${DH2}"

# ── Case 3: drifted_incompatible (used file changed) ────────────────

echo ""
echo "Case 3: drifted_incompatible (used file changed)"
BASELINE_CHANGED="$(baseline_with "sha256:ccc" '{"01-supervisor-agent.md":"sha256:s1","04-frontend-agent.md":"sha256:f2"}')"
RUN3="$(build_run_dir run_003 "${BASELINE_OK}" "${SESS_OK}")"
ENV3="$(verify "${RUN3}" "${BASELINE_CHANGED}")"
V3="$(printf '%s' "${ENV3}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['verdict'])")"
assert_eq "case3: verdict=drifted_incompatible" "drifted_incompatible" "${V3}"
CHANGED3="$(printf '%s' "${ENV3}" | "${PYTHON_BIN}" -c "
import json,sys
d = json.loads(sys.stdin.read())['drift_details']
print(','.join(d['prompt_files_changed']))")"
assert_eq "case3: prompt_files_changed lists 04-frontend-agent.md" \
  "04-frontend-agent.md" "${CHANGED3}"

# ── Case 4: drifted_incompatible (used file removed) ────────────────

echo ""
echo "Case 4: drifted_incompatible (used file removed from current)"
BASELINE_REMOVED="$(baseline_with "sha256:ddd" '{"01-supervisor-agent.md":"sha256:s1"}')"
RUN4="$(build_run_dir run_004 "${BASELINE_OK}" "${SESS_OK}")"
ENV4="$(verify "${RUN4}" "${BASELINE_REMOVED}")"
V4="$(printf '%s' "${ENV4}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['verdict'])")"
assert_eq "case4: verdict=drifted_incompatible (removal)" "drifted_incompatible" "${V4}"
REMOVED4="$(printf '%s' "${ENV4}" | "${PYTHON_BIN}" -c "
import json,sys
d = json.loads(sys.stdin.read())['drift_details']
print(','.join(d['prompt_files_removed']))")"
assert_eq "case4: prompt_files_removed lists 04-frontend-agent.md" \
  "04-frontend-agent.md" "${REMOVED4}"

# ── Case 5: unverifiable (no agent_skills_baseline) ────────────────

echo ""
echo "Case 5: unverifiable (envelope lacks agent_skills_baseline)"
RUN5="${SANDBOX}/run_005"
mkdir -p "${RUN5}"
cat > "${RUN5}/agent-sessions.json" <<'EOF'
{
  "version": 1,
  "run_id": "run_005",
  "workflow_id": "test-workflow",
  "workflow_name": "test",
  "sessions": []
}
EOF
ENV5="$(verify "${RUN5}" "${BASELINE_OK}")"
V5="$(printf '%s' "${ENV5}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['verdict'])")"
assert_eq "case5: verdict=unverifiable" "unverifiable" "${V5}"
OBS5="$(printf '%s' "${ENV5}" | "${PYTHON_BIN}" -c "
import json,sys
print(json.loads(sys.stdin.read())['baseline_observed'])")"
assert_eq "case5: baseline_observed is None" "None" "${OBS5}"

# ── Case 6: not_found (run dir missing) ─────────────────────────────

echo ""
echo "Case 6: not_found (run dir missing)"
ENV6="$(verify "${SANDBOX}/run_does_not_exist" "${BASELINE_OK}")"
V6="$(printf '%s' "${ENV6}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['verdict'])")"
assert_eq "case6: verdict=not_found" "not_found" "${V6}"
BC6="$(printf '%s' "${ENV6}" | "${PYTHON_BIN}" -c "
import json,sys
print(json.loads(sys.stdin.read())['baseline_current'])")"
assert_eq "case6: baseline_current is None when not_found" "None" "${BC6}"

# ── Case 7: --write flag persists verdict + snapshot mirror ─────────

echo ""
echo "Case 7: --write flag creates replay-verdict.json + snapshots/agent-skills.json"
RUN7="$(build_run_dir run_007 "${BASELINE_OK}" "${SESS_OK}")"
verify "${RUN7}" "${BASELINE_OK}" --write >/dev/null

[ -f "${RUN7}/replay-verdict.json" ] && {
  echo "  PASS: case7: replay-verdict.json created"
  pass_count=$((pass_count + 1))
} || {
  echo "  FAIL: case7: replay-verdict.json missing"
  fail_count=$((fail_count + 1))
}

[ -f "${RUN7}/snapshots/agent-skills.json" ] && {
  echo "  PASS: case7: snapshots/agent-skills.json mirror created"
  pass_count=$((pass_count + 1))
} || {
  echo "  FAIL: case7: snapshots/agent-skills.json missing"
  fail_count=$((fail_count + 1))
}

# Mirror MUST contain prompt_files (full baseline, not summary)
MIRROR_HAS_PROMPT_FILES="$("${PYTHON_BIN}" -c "
import json
d = json.load(open('${RUN7}/snapshots/agent-skills.json'))
print('prompt_files' in d)")"
assert_eq "case7: snapshot mirror carries prompt_files (full baseline)" \
  "True" "${MIRROR_HAS_PROMPT_FILES}"

# Idempotent re-write: rerun --write, verdict file mtime should be stable
# since content didn't change. Compare json content to confirm stability.
verify "${RUN7}" "${BASELINE_OK}" --write >/dev/null
VERDICT_AFTER="$("${PYTHON_BIN}" -c "
import json
print(json.load(open('${RUN7}/replay-verdict.json'))['verdict'])")"
assert_eq "case7: verdict file stable across reruns" "replayable" "${VERDICT_AFTER}"

# ── Case 8: CLI exit code per verdict ───────────────────────────────

echo ""
echo "Case 8: CLI exit codes (replayable=0, incompatible=4, not_found=2)"

# Build an env-injected wrapper because the real CLI computes a
# current snapshot on its own; we override CAP_AGENT_SKILLS_DIR so the
# CLI hashes a sandbox dir rather than the real cap-protocols repo.
SAND_AGENT_SKILLS="${SANDBOX}/sand_agent_skills"
mkdir -p "${SAND_AGENT_SKILLS}"
cat > "${SAND_AGENT_SKILLS}/01-supervisor-agent.md" <<'EOF'
# Supervisor sandbox prompt
EOF
cat > "${SAND_AGENT_SKILLS}/04-frontend-agent.md" <<'EOF'
# Frontend sandbox prompt
EOF

# Build a fixture run dir whose stored baseline was generated by
# compute_snapshot against the same sandbox so the CLI run will
# resolve to verdict=replayable (deterministic).
SAND_BASELINE="$(CAP_AGENT_SKILLS_DIR="${SAND_AGENT_SKILLS}" CAP_ROOT="${SANDBOX}" \
  "${PYTHON_BIN}" "${REPO_ROOT}/engine/agent_skills_snapshot.py" snapshot)"
RUN8="$(build_run_dir run_008 "${SAND_BASELINE}" "${SESS_OK}")"

CAP_AGENT_SKILLS_DIR="${SAND_AGENT_SKILLS}" CAP_ROOT="${SANDBOX}" \
  "${PYTHON_BIN}" "${VERIFIER_PY}" verify "${RUN8}" >/dev/null
EXIT_REPLAYABLE=$?
assert_eq "case8: replayable exit code = 0" "0" "${EXIT_REPLAYABLE}"

# Modify the sandbox to force drifted_incompatible
echo "# Frontend sandbox prompt EDITED" > "${SAND_AGENT_SKILLS}/04-frontend-agent.md"
CAP_AGENT_SKILLS_DIR="${SAND_AGENT_SKILLS}" CAP_ROOT="${SANDBOX}" \
  "${PYTHON_BIN}" "${VERIFIER_PY}" verify "${RUN8}" >/dev/null
EXIT_INCOMPATIBLE=$?
assert_eq "case8: drifted_incompatible exit code = 4" "4" "${EXIT_INCOMPATIBLE}"

CAP_AGENT_SKILLS_DIR="${SAND_AGENT_SKILLS}" CAP_ROOT="${SANDBOX}" \
  "${PYTHON_BIN}" "${VERIFIER_PY}" verify "${SANDBOX}/missing_run" >/dev/null 2>&1
EXIT_NOT_FOUND=$?
assert_eq "case8: not_found exit code = 2" "2" "${EXIT_NOT_FOUND}"

# ── Case 9: every emitted envelope passes the schema ───────────────

echo ""
echo "Case 9: every produced envelope validates against replay-verdict schema"
for ENV in "${ENV1}" "${ENV2}" "${ENV3}" "${ENV4}" "${ENV5}" "${ENV6}"; do
  PROBE="${SANDBOX}/probe.json"
  printf '%s' "${ENV}" > "${PROBE}"
  "${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${PROBE}" "${SCHEMA_PATH}" >/dev/null 2>&1
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    echo "  PASS: case9: envelope validates"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: case9: envelope failed schema (rc=${rc})"
    echo "    payload preview: $(printf '%s' "${ENV}" | head -2 | tr '\n' ' ')"
    fail_count=$((fail_count + 1))
  fi
done

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
