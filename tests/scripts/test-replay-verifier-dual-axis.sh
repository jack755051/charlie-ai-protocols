#!/usr/bin/env bash
#
# test-replay-verifier-dual-axis.sh — H2 #5 focused dual-axis tests.
#
# Cases (4 aggregation scenarios + binding_summary helper + edge cases):
#   1. both axes replayable → top-level replayable
#   2. builtin replayable + project drifted_compatible → drifted_compatible
#   3. builtin drifted_incompatible + project replayable → drifted_incompatible
#   4. builtin replayable + project drifted_incompatible → drifted_incompatible
#   5. project_skill_baseline only (no binding_summary) → coarse drift,
#      axis_verdict caps at drifted_compatible (not incompatible)
#   6. neither project_skill_baseline nor binding_summary →
#      axis_verdict=unverifiable_axis (no top-level downgrade)
#   7. binding_summary.extract_from_plan walks phases + standby_steps
#      and dedupes step_ids
#   8. project_skill_diff object body always present when
#      baseline_observed is non-null (was_recorded=false neutral path)
#
# Reference SSOT:
#   - docs/cap/H2-PROJECT-SKILL-DRIFT-DESIGN.md §4 aggregation rules
#   - engine/replay_verifier.py:_compute_project_axis / _aggregate_axes
#   - engine/binding_summary.py:extract_from_plan

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -f "${REPO_ROOT}/engine/replay_verifier.py" ] || {
  echo "FAIL: replay_verifier.py missing"; exit 1;
}
[ -f "${REPO_ROOT}/engine/binding_summary.py" ] || {
  echo "FAIL: binding_summary.py missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-replay-dual-axis-test.XXXXXX)"
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

# Helper that builds a fixture run dir and invokes verify_run with
# injected snapshots. Prints the full verdict envelope JSON.
verify_with_injection() {
  local run_dir="$1"
  local builtin_observed="$2"
  local builtin_current="$3"
  local project_observed="$4"
  local project_current="$5"
  local binding_summary="$6"
  local sessions="$7"

  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${run_dir}" \
    "${builtin_observed}" "${builtin_current}" \
    "${project_observed}" "${project_current}" \
    "${binding_summary}" "${sessions}" <<'PY'
import json
import sys
from pathlib import Path
from datetime import datetime, timezone

from engine import replay_verifier as rv

(
    run_dir, b_obs, b_cur, p_obs, p_cur, bsum, sess
) = sys.argv[1:8]
run_dir = Path(run_dir)
b_obs = json.loads(b_obs) if b_obs else None
b_cur = json.loads(b_cur)
p_obs = json.loads(p_obs) if p_obs else None
p_cur = json.loads(p_cur)
bsum = json.loads(bsum) if bsum else None
sess = json.loads(sess)

run_dir.mkdir(parents=True, exist_ok=True)
envelope = {
    "version": 1,
    "run_id": run_dir.name,
    "workflow_id": "dual-axis-test",
    "workflow_name": "test",
    "sessions": sess,
}
if b_obs is not None:
    envelope["agent_skills_baseline"] = b_obs
if p_obs is not None:
    envelope["project_skill_baseline"] = p_obs
if bsum is not None:
    envelope["binding_summary"] = bsum

(run_dir / "agent-sessions.json").write_text(
    json.dumps(envelope, ensure_ascii=False, indent=2),
    encoding="utf-8",
)

verdict = rv.verify_run(
    run_dir,
    current_snapshot=b_cur,
    project_skills_current=p_cur,
    verified_at=datetime(2026, 5, 7, 3, 0, 0, tzinfo=timezone.utc),
)
print(json.dumps(verdict, ensure_ascii=False, indent=2))
PY
}

# Compact builders.
builtin_baseline() {
  local dir_hash="$1" prompt_files="$2"
  cat <<EOF
{
  "cap_version": "v0.22.0",
  "git_commit": "abc1234",
  "git_dirty": false,
  "computed_at": "2026-05-06T00:00:00Z",
  "dir_hash": "${dir_hash}",
  "prompt_files": ${prompt_files},
  "baseline_root": "/tmp/agent-skills"
}
EOF
}

project_baseline() {
  local dir_hash="$1" skills_by_id="$2"
  cat <<EOF
{
  "project_root": "/tmp/proj",
  "project_dir_present": true,
  "flat_registry": {"path": "/tmp/proj/.cap/skills.yaml", "hash": "sha256:flat${dir_hash}"},
  "per_skill_files": {},
  "skills_by_id": ${skills_by_id},
  "dir_hash": "${dir_hash}",
  "computed_at": "2026-05-06T00:00:00Z"
}
EOF
}

binding_summary_steps() {
  local steps="$1"
  cat <<EOF
{
  "schema_version": 1,
  "captured_at": "2026-05-06T00:00:00Z",
  "steps": ${steps}
}
EOF
}

# Common fixture pieces.
SESSIONS_FE='[{"session_id":"s1","prompt_file":"agent-skills/01-supervisor-agent.md"}]'
B_OBS_OK="$(builtin_baseline 'sha256:bb' '{"01-supervisor-agent.md":"sha256:s1"}')"
B_OBS_OK_NO_FE="$(builtin_baseline 'sha256:bb' '{"01-supervisor-agent.md":"sha256:s1"}')"
B_CUR_SAME="$(builtin_baseline 'sha256:bb' '{"01-supervisor-agent.md":"sha256:s1"}')"
B_CUR_SAME_NO_FE="${B_CUR_SAME}"
B_CUR_FE_CHANGED="$(builtin_baseline 'sha256:bbnew' '{"01-supervisor-agent.md":"sha256:s2"}')"

P_OBS_OK="$(project_baseline 'sha256:pp' '{"my-frontend":{"hash":"sha256:fe1","source_path":"/p"},"my-qa":{"hash":"sha256:qa1","source_path":"/p"}}')"
P_CUR_SAME="${P_OBS_OK}"
P_CUR_FE_CHANGED="$(project_baseline 'sha256:pp2' '{"my-frontend":{"hash":"sha256:fe2","source_path":"/p"},"my-qa":{"hash":"sha256:qa1","source_path":"/p"}}')"
P_CUR_DIR_DIFF_USED_OK="$(project_baseline 'sha256:pp3' '{"my-frontend":{"hash":"sha256:fe1","source_path":"/p"},"my-qa":{"hash":"sha256:qa1","source_path":"/p"},"unused-extra":{"hash":"sha256:newadd","source_path":"/p"}}')"

BS_USES_PROJECT_FE="$(binding_summary_steps '[{"step_id":"s1","selected_skill_id":"my-frontend","skill_source":{"source_layer":"project","source_path":"/p"}}]')"

# ── Case 1: both axes replayable ────────────────────────────────────

echo "Case 1: both axes replayable → top-level replayable"
RUN1="${SANDBOX}/run_001"
ENV1="$(verify_with_injection "${RUN1}" "${B_OBS_OK}" "${B_CUR_SAME}" "${P_OBS_OK}" "${P_CUR_SAME}" "${BS_USES_PROJECT_FE}" "${SESSIONS_FE}")"
V1="$(printf '%s' "${ENV1}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['verdict'])")"
assert_eq "case1: verdict=replayable" "replayable" "${V1}"
P1_AX="$(printf '%s' "${ENV1}" | "${PYTHON_BIN}" -c "
import json,sys
print(json.loads(sys.stdin.read())['drift_details']['project_skill_diff']['axis_verdict'])")"
assert_eq "case1: project axis_verdict=replayable" "replayable" "${P1_AX}"

# ── Case 2: project drifted_compatible only → drifted_compatible ────

echo ""
echo "Case 2: builtin replayable + project drifted_compatible (unused dir change)"
RUN2="${SANDBOX}/run_002"
ENV2="$(verify_with_injection "${RUN2}" "${B_OBS_OK}" "${B_CUR_SAME}" "${P_OBS_OK}" "${P_CUR_DIR_DIFF_USED_OK}" "${BS_USES_PROJECT_FE}" "${SESSIONS_FE}")"
V2="$(printf '%s' "${ENV2}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['verdict'])")"
assert_eq "case2: verdict=drifted_compatible" "drifted_compatible" "${V2}"
P2_AX="$(printf '%s' "${ENV2}" | "${PYTHON_BIN}" -c "
import json,sys
print(json.loads(sys.stdin.read())['drift_details']['project_skill_diff']['axis_verdict'])")"
assert_eq "case2: project axis_verdict=drifted_compatible" "drifted_compatible" "${P2_AX}"

# ── Case 3: builtin incompatible + project replayable → incompatible ─

echo ""
echo "Case 3: builtin drifted_incompatible + project replayable"
RUN3="${SANDBOX}/run_003"
ENV3="$(verify_with_injection "${RUN3}" "${B_OBS_OK}" "${B_CUR_FE_CHANGED}" "${P_OBS_OK}" "${P_CUR_SAME}" "${BS_USES_PROJECT_FE}" "${SESSIONS_FE}")"
V3="$(printf '%s' "${ENV3}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['verdict'])")"
assert_eq "case3: verdict=drifted_incompatible (builtin axis dominates)" \
  "drifted_incompatible" "${V3}"
P3_AX="$(printf '%s' "${ENV3}" | "${PYTHON_BIN}" -c "
import json,sys
print(json.loads(sys.stdin.read())['drift_details']['project_skill_diff']['axis_verdict'])")"
assert_eq "case3: project axis still replayable" "replayable" "${P3_AX}"

# ── Case 4: builtin replayable + project incompatible → incompatible ─

echo ""
echo "Case 4: builtin replayable + project drifted_incompatible"
RUN4="${SANDBOX}/run_004"
ENV4="$(verify_with_injection "${RUN4}" "${B_OBS_OK}" "${B_CUR_SAME}" "${P_OBS_OK}" "${P_CUR_FE_CHANGED}" "${BS_USES_PROJECT_FE}" "${SESSIONS_FE}")"
V4="$(printf '%s' "${ENV4}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['verdict'])")"
assert_eq "case4: verdict=drifted_incompatible (project axis dominates)" \
  "drifted_incompatible" "${V4}"
CHANGED4="$(printf '%s' "${ENV4}" | "${PYTHON_BIN}" -c "
import json,sys
print(','.join(json.loads(sys.stdin.read())['drift_details']['project_skill_diff']['skills_changed']))")"
assert_eq "case4: skills_changed lists my-frontend" "my-frontend" "${CHANGED4}"

# ── Case 5: project baseline only, no binding_summary ───────────────

echo ""
echo "Case 5: project_skill_baseline only (no binding_summary) → coarse drift"
RUN5="${SANDBOX}/run_005"
# Same as case 4 inputs but binding_summary missing → cannot pinpoint
# skills_used, axis caps at drifted_compatible.
ENV5="$(verify_with_injection "${RUN5}" "${B_OBS_OK}" "${B_CUR_SAME}" "${P_OBS_OK}" "${P_CUR_FE_CHANGED}" "" "${SESSIONS_FE}")"
V5="$(printf '%s' "${ENV5}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['verdict'])")"
P5_AX="$(printf '%s' "${ENV5}" | "${PYTHON_BIN}" -c "
import json,sys
print(json.loads(sys.stdin.read())['drift_details']['project_skill_diff']['axis_verdict'])")"
P5_RECORDED="$(printf '%s' "${ENV5}" | "${PYTHON_BIN}" -c "
import json,sys
print(json.loads(sys.stdin.read())['drift_details']['project_skill_diff']['was_recorded'])")"
assert_eq "case5: top-level=drifted_compatible (cannot prove incompatible)" \
  "drifted_compatible" "${V5}"
assert_eq "case5: project axis=drifted_compatible (coarse)" \
  "drifted_compatible" "${P5_AX}"
assert_eq "case5: was_recorded=false (binding_summary missing)" \
  "False" "${P5_RECORDED}"

# ── Case 6: project baseline absent (was_recorded=false neutral) ────

echo ""
echo "Case 6: no project_skill_baseline + no binding_summary → unverifiable_axis"
RUN6="${SANDBOX}/run_006"
ENV6="$(verify_with_injection "${RUN6}" "${B_OBS_OK}" "${B_CUR_SAME}" "" "${P_CUR_SAME}" "" "${SESSIONS_FE}")"
V6="$(printf '%s' "${ENV6}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['verdict'])")"
P6_AX="$(printf '%s' "${ENV6}" | "${PYTHON_BIN}" -c "
import json,sys
print(json.loads(sys.stdin.read())['drift_details']['project_skill_diff']['axis_verdict'])")"
assert_eq "case6: top-level=replayable (project neutral, builtin replayable wins)" \
  "replayable" "${V6}"
assert_eq "case6: project axis_verdict=unverifiable_axis" \
  "unverifiable_axis" "${P6_AX}"

# ── Case 7: binding_summary.extract_from_plan walks phases + standby ─

echo ""
echo "Case 7: extract_from_plan dedupes + walks phases + standby_steps"
PLAN_TMP="${SANDBOX}/plan.json"
cat > "${PLAN_TMP}" <<'EOF'
{
  "workflow_id": "wf",
  "phases": [
    {
      "phase": 1,
      "steps": [
        {"step_id": "s1", "skill_id": "builtin-frontend", "skill_source": {"source_layer": "builtin", "source_path": "/b"}},
        {"step_id": "s2", "skill_id": "my-qa", "skill_source": {"source_layer": "project", "source_path": "/p"}}
      ]
    },
    {
      "phase": 2,
      "steps": [
        {"step_id": "s3", "skill_id": null, "skill_source": null}
      ]
    }
  ],
  "standby_steps": [
    {"step_id": "s4", "skill_id": "generic-implementer", "skill_source": {"source_layer": "fallback", "source_path": null}},
    {"step_id": "s2", "skill_id": "my-qa", "skill_source": {"source_layer": "project", "source_path": "/p"}}
  ]
}
EOF
SUMMARY="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" "${REPO_ROOT}/engine/binding_summary.py" extract "${PLAN_TMP}")"
SUMMARY_STEPS_COUNT="$(printf '%s' "${SUMMARY}" | "${PYTHON_BIN}" -c "
import json,sys
print(len(json.loads(sys.stdin.read())['steps']))")"
assert_eq "case7: extracted 4 distinct step_ids (s1/s2/s3/s4, s2 dedup)" \
  "4" "${SUMMARY_STEPS_COUNT}"
SUMMARY_S2_LAYER="$(printf '%s' "${SUMMARY}" | "${PYTHON_BIN}" -c "
import json,sys
data = json.loads(sys.stdin.read())
s2 = next(s for s in data['steps'] if s['step_id'] == 's2')
print(s2['skill_source']['source_layer'])")"
assert_eq "case7: s2 keeps project source_layer" "project" "${SUMMARY_S2_LAYER}"

# ── Case 8: project_skill_diff object always present when observed exists ─

echo ""
echo "Case 8: project_skill_diff object body emitted for every non-null baseline"
RUN8="${SANDBOX}/run_008"
ENV8="$(verify_with_injection "${RUN8}" "${B_OBS_OK}" "${B_CUR_SAME}" "" "${P_CUR_SAME}" "" "${SESSIONS_FE}")"
P8_TYPE="$(printf '%s' "${ENV8}" | "${PYTHON_BIN}" -c "
import json,sys
psd = json.loads(sys.stdin.read())['drift_details']['project_skill_diff']
print('object' if isinstance(psd, dict) else type(psd).__name__)")"
assert_eq "case8: project_skill_diff is object (not null) when observed exists" \
  "object" "${P8_TYPE}"

# Also confirm: when no agent_skills_baseline (pre-A0 #4) → null retained.
RUN8B="${SANDBOX}/run_008b"
ENV8B="$(verify_with_injection "${RUN8B}" "" "${B_CUR_SAME}" "" "${P_CUR_SAME}" "" "${SESSIONS_FE}")"
P8B_DIFF="$(printf '%s' "${ENV8B}" | "${PYTHON_BIN}" -c "
import json,sys
print(json.loads(sys.stdin.read())['drift_details']['project_skill_diff'])")"
assert_eq "case8b: project_skill_diff stays None when baseline_observed=null" \
  "None" "${P8B_DIFF}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
