#!/usr/bin/env bash
#
# test-orchestration-snapshot.sh — Smoke for engine/orchestration_snapshot.py
# (P3 #5-a four-part snapshot writer).
#
# Coverage scope, per the P3 #5-a ratification (Q1 = A, four-part snapshot
# always lands; Q2 = A, full envelope only; Q3 = A, legacy reconstruct
# untouched):
#
#   Case 0 happy:           valid envelope passes extract + schema + drift;
#                           four artefacts on disk; validation.json
#                           status=ok; exit 0.
#   Case 1 missing fence:   envelope artifact has no fence pair; CLI exits
#                           41; four-part snapshot still lands;
#                           validation.json status=failed with extraction
#                           error captured; envelope.json gets sentinel.
#   Case 2 schema invalid:  fence parses but jsonschema rejects (missing
#                           failure_routing required); CLI exits 41;
#                           four artefacts land; validation.json status=
#                           failed; envelope.json carries the broken
#                           payload verbatim (operator can inspect it).
#   Case 3 drift detected:  schema-valid envelope but envelope.task_id
#                           drifts from task_constitution.task_id;
#                           CLI exits 41; four artefacts land;
#                           validation.json drift section names "task_id
#                           drift"; envelope.json verbatim.
#   Case 4 missing artifact: --envelope-path points at a non-existent
#                           file; CLI exits 41; nothing written.
#   Case 5 invalid stamp:   --stamp shape is wrong; CLI exits 41 BEFORE
#                           any disk write so the operator is forced to
#                           fix the input.
#   Case 6 pure helper:     write_snapshot() called directly with a
#                           caller-provided validation_report = failed
#                           lands all four artefacts (Q1 = A guarantee
#                           holds at the helper layer, not just the CLI).
#
# Determinism: the writer is a pure helper plus a thin CLI; all fixtures
# are inline files under a per-case CAP_HOME sandbox so cross-case state
# cannot leak. Zero AI / zero network / zero installed cap binary.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WRITER_MODULE="${REPO_ROOT}/engine/orchestration_snapshot.py"

[ -f "${WRITER_MODULE}" ] || { echo "FAIL: ${WRITER_MODULE} missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-orchestration-snapshot.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected: ${expected}"
    echo "    actual:   ${actual}"
    fail_count=$((fail_count + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to contain: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [ -f "${path}" ]; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc} (missing: ${path})"
    fail_count=$((fail_count + 1))
  fi
}

assert_file_absent() {
  local desc="$1" path="$2"
  if [ ! -e "${path}" ]; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc} (unexpected: ${path})"
    fail_count=$((fail_count + 1))
  fi
}

# Run the CLI under an isolated CAP_HOME and stamp; returns "STDOUT|STDERR|EXIT".
run_writer() {
  local cap_home="$1" envelope_path="$2"
  shift 2
  local out err code tmp_out tmp_err
  tmp_out="$(mktemp)"; tmp_err="$(mktemp)"
  set +e
  CAP_HOME="${cap_home}" python3 -m engine.orchestration_snapshot write \
    --envelope-path "${envelope_path}" \
    --project-id "smoke-proj" \
    "$@" >"${tmp_out}" 2>"${tmp_err}"
  code=$?
  set -e
  out="$(cat "${tmp_out}")"; err="$(cat "${tmp_err}")"
  rm -f "${tmp_out}" "${tmp_err}"
  printf '%s|%s|%s' "${out}" "${err}" "${code}"
}

# Helper: emit a fully-valid envelope artifact with caller-overridable
# task_id drift fields. Default arguments produce an aligned envelope.
emit_envelope() {
  local target="$1"
  local envelope_task_id="${2:-smoke-001}"
  local nested_task_id="${3:-${envelope_task_id}}"
  cat > "${target}" <<EOF
narrative line above the fence

<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>
{
  "schema_version": 1,
  "task_id": "${envelope_task_id}",
  "source_request": "smoke source",
  "produced_at": "2026-05-03T22:00:00Z",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {
    "task_id": "${nested_task_id}",
    "project_id": "smoke-proj",
    "source_request": "smoke source",
    "goal": "exercise snapshot writer",
    "goal_stage": "informal_planning",
    "success_criteria": ["four-part snapshot lands"],
    "non_goals": [],
    "execution_plan": [{"step_id":"prd","capability":"prd_generation"}]
  },
  "capability_graph": {
    "schema_version": 1,
    "task_id": "${envelope_task_id}",
    "goal_stage": "informal_planning",
    "nodes": [{"step_id":"prd","capability":"prd_generation","required":true,"depends_on":[],"reason":"scope"}]
  },
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {"default_action": "halt", "overrides": []}
}
<<<SUPERVISOR_ORCHESTRATION_END>>>
EOF
}

STAMP="20260503T120000Z"

# ── Case 0 ──────────────────────────────────────────────────────────────
echo "Case 0: happy path → exit 0, four-part snapshot, status=ok"
C0_HOME="${SANDBOX}/c0-cap"
C0_ART="${SANDBOX}/c0-envelope.md"
emit_envelope "${C0_ART}"
result="$(run_writer "${C0_HOME}" "${C0_ART}" --stamp "${STAMP}")"
out0="${result%%|*}"; rest="${result#*|}"; exit0="${rest##*|}"
assert_eq "case 0 exit 0" "0" "${exit0}"
assert_contains "case 0 status=ok" '"status": "ok"' "${out0}"
assert_contains "case 0 extraction_ok=true" '"extraction_ok": true' "${out0}"
assert_contains "case 0 validation_ok=true" '"validation_ok": true' "${out0}"
assert_contains "case 0 drift_ok=true" '"drift_ok": true' "${out0}"
C0_DIR="${C0_HOME}/projects/smoke-proj/orchestrations/${STAMP}"
assert_file_exists "case 0 envelope.json" "${C0_DIR}/envelope.json"
assert_file_exists "case 0 envelope.md" "${C0_DIR}/envelope.md"
assert_file_exists "case 0 validation.json" "${C0_DIR}/validation.json"
assert_file_exists "case 0 source-prompt.txt" "${C0_DIR}/source-prompt.txt"
v0="$(cat "${C0_DIR}/validation.json")"
assert_contains "case 0 validation.json status=ok" '"status": "ok"' "${v0}"
md0="$(cat "${C0_DIR}/envelope.md")"
assert_contains "case 0 envelope.md names task_id" "smoke-001" "${md0}"

# Verify envelope.json round-trips: parse and read schema_version.
parsed_sv="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("schema_version", "<missing>"))
' "${C0_DIR}/envelope.json")"
assert_eq "case 0 envelope.json schema_version=1" "1" "${parsed_sv}"

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: missing fence → exit 41, four artefacts still land (Q1=A)"
C1_HOME="${SANDBOX}/c1-cap"
C1_ART="${SANDBOX}/c1-no-fence.md"
cat > "${C1_ART}" <<'EOF'
# Supervisor reply (no fence)

The supervisor wrote prose only and forgot to wrap the canonical JSON
in <<<SUPERVISOR_ORCHESTRATION_BEGIN/END>>> markers. Extraction fails,
but the snapshot writer must still land all four artefacts so doctor /
status can observe partial state.
EOF
result="$(run_writer "${C1_HOME}" "${C1_ART}" --stamp "${STAMP}")"
out1="${result%%|*}"; rest="${result#*|}"; exit1="${rest##*|}"
assert_eq "case 1 exit 41" "41" "${exit1}"
assert_contains "case 1 status=failed" '"status": "failed"' "${out1}"
assert_contains "case 1 extraction_ok=false" '"extraction_ok": false' "${out1}"
C1_DIR="${C1_HOME}/projects/smoke-proj/orchestrations/${STAMP}"
assert_file_exists "case 1 envelope.json still written" "${C1_DIR}/envelope.json"
assert_file_exists "case 1 envelope.md still written" "${C1_DIR}/envelope.md"
assert_file_exists "case 1 validation.json still written" "${C1_DIR}/validation.json"
assert_file_exists "case 1 source-prompt.txt still written" "${C1_DIR}/source-prompt.txt"
v1="$(cat "${C1_DIR}/validation.json")"
assert_contains "case 1 validation.json status=failed" '"status": "failed"' "${v1}"
assert_contains "case 1 validation.json names extraction error" "missing envelope fence" "${v1}"
ej1="$(cat "${C1_DIR}/envelope.json")"
assert_contains "case 1 envelope.json carries sentinel" \
  "_orchestration_snapshot_note" "${ej1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: schema invalid (missing failure_routing) → exit 41, all four land"
C2_HOME="${SANDBOX}/c2-cap"
C2_ART="${SANDBOX}/c2-schema-bad.md"
cat > "${C2_ART}" <<'EOF'
<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>
{
  "schema_version": 1,
  "task_id": "smoke-002",
  "source_request": "missing failure_routing",
  "produced_at": "2026-05-03T22:00:00Z",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {
    "task_id": "smoke-002",
    "project_id": "smoke-proj",
    "source_request": "missing failure_routing",
    "goal": "exercise schema fail",
    "goal_stage": "informal_planning",
    "success_criteria": ["schema must reject"],
    "non_goals": [],
    "execution_plan": [{"step_id":"prd","capability":"prd_generation"}]
  },
  "capability_graph": {
    "schema_version": 1,
    "task_id": "smoke-002",
    "goal_stage": "informal_planning",
    "nodes": [{"step_id":"prd","capability":"prd_generation","required":true,"depends_on":[],"reason":"scope"}]
  },
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {}
}
<<<SUPERVISOR_ORCHESTRATION_END>>>
EOF
result="$(run_writer "${C2_HOME}" "${C2_ART}" --stamp "${STAMP}")"
out2="${result%%|*}"; rest="${result#*|}"; exit2="${rest##*|}"
assert_eq "case 2 exit 41" "41" "${exit2}"
assert_contains "case 2 status=failed" '"status": "failed"' "${out2}"
assert_contains "case 2 extraction_ok=true" '"extraction_ok": true' "${out2}"
assert_contains "case 2 validation_ok=false" '"validation_ok": false' "${out2}"
C2_DIR="${C2_HOME}/projects/smoke-proj/orchestrations/${STAMP}"
assert_file_exists "case 2 envelope.json" "${C2_DIR}/envelope.json"
assert_file_exists "case 2 envelope.md" "${C2_DIR}/envelope.md"
assert_file_exists "case 2 validation.json" "${C2_DIR}/validation.json"
assert_file_exists "case 2 source-prompt.txt" "${C2_DIR}/source-prompt.txt"
v2="$(cat "${C2_DIR}/validation.json")"
assert_contains "case 2 validation.json names failure_routing" "failure_routing" "${v2}"
ej2="$(cat "${C2_DIR}/envelope.json")"
assert_contains "case 2 envelope.json keeps original task_id" '"task_id": "smoke-002"' "${ej2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: drift detected → exit 41, all four land, drift section populated"
C3_HOME="${SANDBOX}/c3-cap"
C3_ART="${SANDBOX}/c3-drift.md"
emit_envelope "${C3_ART}" "envelope-says-X" "nested-says-Y"
result="$(run_writer "${C3_HOME}" "${C3_ART}" --stamp "${STAMP}")"
out3="${result%%|*}"; rest="${result#*|}"; exit3="${rest##*|}"
assert_eq "case 3 exit 41" "41" "${exit3}"
assert_contains "case 3 status=failed" '"status": "failed"' "${out3}"
assert_contains "case 3 drift_ok=false" '"drift_ok": false' "${out3}"
C3_DIR="${C3_HOME}/projects/smoke-proj/orchestrations/${STAMP}"
assert_file_exists "case 3 envelope.json" "${C3_DIR}/envelope.json"
assert_file_exists "case 3 envelope.md" "${C3_DIR}/envelope.md"
assert_file_exists "case 3 validation.json" "${C3_DIR}/validation.json"
assert_file_exists "case 3 source-prompt.txt" "${C3_DIR}/source-prompt.txt"
v3="$(cat "${C3_DIR}/validation.json")"
assert_contains "case 3 validation.json names task_id drift" "task_id drift" "${v3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: missing artifact path → exit 41, nothing written"
C4_HOME="${SANDBOX}/c4-cap"
C4_ART="${SANDBOX}/c4-does-not-exist.md"
result="$(run_writer "${C4_HOME}" "${C4_ART}" --stamp "${STAMP}")"
err4="${result#*|}"; err4="${err4%|*}"; exit4="${result##*|}"
assert_eq "case 4 exit 41" "41" "${exit4}"
assert_contains "case 4 stderr names missing artifact" "envelope artifact not found" "${err4}"
assert_file_absent "case 4 no snapshot dir" \
  "${C4_HOME}/projects/smoke-proj/orchestrations/${STAMP}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: invalid stamp shape → exit 41, nothing written"
C5_HOME="${SANDBOX}/c5-cap"
C5_ART="${SANDBOX}/c5-envelope.md"
emit_envelope "${C5_ART}"
result="$(run_writer "${C5_HOME}" "${C5_ART}" --stamp "bad-shape")"
err5="${result#*|}"; err5="${err5%|*}"; exit5="${result##*|}"
assert_eq "case 5 exit 41" "41" "${exit5}"
assert_contains "case 5 stderr names stamp shape" "does not match" "${err5}"
assert_file_absent "case 5 no snapshot dir" \
  "${C5_HOME}/projects/smoke-proj/orchestrations/bad-shape"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: pure write_snapshot() helper with caller-failed report"
# Exercise the Python-level public API directly so the Q1 = A guarantee
# is proven independently of the CLI surface. We fabricate a payload-less
# call (envelope_payload=None) and a failed validation_report.
C6_HOME="${SANDBOX}/c6-cap"
mkdir -p "${C6_HOME}"
python3 - "${C6_HOME}" "${STAMP}" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, "/home/jack755051/projects/charlie-ai-protocols")
from engine.orchestration_snapshot import write_snapshot

cap_home = Path(sys.argv[1])
stamp = sys.argv[2]
report = {
    "status": "failed",
    "stamp": stamp,
    "extraction": {"ok": False, "error": "fabricated extraction failure"},
    "validation": None,
    "drift": None,
}
paths = write_snapshot(
    project_id="smoke-proj",
    cap_home=cap_home,
    stamp=stamp,
    envelope_payload=None,
    validation_report=report,
    source_prompt="(synthetic) caller-driven failure path",
)
print(json.dumps(paths.to_dict(), indent=2, ensure_ascii=False))
PY
C6_DIR="${C6_HOME}/projects/smoke-proj/orchestrations/${STAMP}"
assert_file_exists "case 6 envelope.json (helper-only)" "${C6_DIR}/envelope.json"
assert_file_exists "case 6 envelope.md (helper-only)" "${C6_DIR}/envelope.md"
assert_file_exists "case 6 validation.json (helper-only)" "${C6_DIR}/validation.json"
assert_file_exists "case 6 source-prompt.txt (helper-only)" "${C6_DIR}/source-prompt.txt"
v6="$(cat "${C6_DIR}/validation.json")"
assert_contains "case 6 validation.json status=failed" '"status": "failed"' "${v6}"
ej6="$(cat "${C6_DIR}/envelope.json")"
assert_contains "case 6 envelope.json sentinel under None payload" \
  "_orchestration_snapshot_note" "${ej6}"
md6="$(cat "${C6_DIR}/envelope.md")"
assert_contains "case 6 envelope.md placeholder for failed extract" \
  "extraction failed" "${md6}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
