#!/usr/bin/env bash
#
# test-validate-inputs-intrinsic-vs-registry.sh — Lock the v0.25.3
# resolution-order contract for step_runtime.validate_inputs.
#
# Pre-fix bug:
#   _try_resolve checked _INTRINSIC_ARTIFACTS first; if the artifact
#   name appeared there but the intrinsic source (e.g. on-disk
#   .cap.constitution.yaml) did not exist, it returned None — without
#   ever consulting the runtime artifact registry. Any workflow that
#   produces an intrinsic-named artifact in its own run (e.g.
#   project-constitution's draft_constitution producing
#   project_constitution for the validate_constitution step) had its
#   self-produced output silently masked by the intrinsic branch and
#   the next step blocked with missing_input_artifact.
#
# Fix (v0.25.3):
#   Registry first (validated upstream wins), intrinsic second (only
#   when no upstream produced the artifact).
#
# Coverage:
#   Case 1: registry has a validated artifact named project_constitution
#           (produced by an upstream draft step) AND .cap.constitution.yaml
#           does NOT exist on disk. Pre-fix: missing. Post-fix: resolved
#           from registry.
#
#   Case 2: registry does NOT have project_constitution AND
#           .cap.constitution.yaml DOES exist on disk. Pre-fix: resolved
#           from intrinsic. Post-fix: resolved from intrinsic (unchanged).
#
#   Case 3: registry has a validated upstream produce of
#           project_constitution AND .cap.constitution.yaml ALSO exists
#           on disk. Post-fix: registry wins (same-run draft beats
#           project-level persisted file).
#
#   Case 4: neither registry nor intrinsic source — missing. Pre-fix
#           and post-fix both: missing. (Sanity check; no behaviour
#           change.)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${STEP_PY}" ] || { echo "FAIL: step_runtime.py missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-validate-inputs-test.XXXXXX)"
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

# Helper: run validate-inputs with a custom plan + registry, return ok/missing/source_step
run_validate() {
  local plan="$1" registry_path="$2" step_id="$3" cwd="$4"
  ( cd "${cwd}" && "${PYTHON_BIN}" "${STEP_PY}" validate-inputs "${plan}" "${step_id}" "${registry_path}" )
}

# Build a minimal flatten-plan-shaped JSON with one step that needs project_constitution.
build_plan() {
  cat <<'JSON'
{
  "phases": [
    {
      "phase": 1,
      "steps": [
        {
          "step_id": "validate_constitution",
          "phase": 1,
          "capability": "constitution_validation",
          "needs": ["draft_constitution"],
          "inputs": ["project_constitution"],
          "outputs": []
        }
      ]
    }
  ],
  "steps": [
    {
      "step_id": "validate_constitution",
      "phase": 1,
      "capability": "constitution_validation",
      "needs": ["draft_constitution"],
      "inputs": ["project_constitution"],
      "outputs": []
    }
  ]
}
JSON
}

# ── Case 1: registry validated, no disk file ────────────────────────
echo "Case 1: registry has validated upstream, no .cap.constitution.yaml on disk"
case1_dir="${SANDBOX}/case1"
mkdir -p "${case1_dir}"
case1_registry="${case1_dir}/runtime-state.json"
cat > "${case1_registry}" <<EOF
{
  "artifacts": {
    "project_constitution": {
      "artifact": "project_constitution",
      "source_step": "draft_constitution",
      "path": "${case1_dir}/draft.md",
      "handoff_path": "${case1_dir}/draft.handoff.md"
    }
  },
  "steps": {
    "draft_constitution": {
      "execution_state": "validated"
    }
  }
}
EOF
echo "draft body" > "${case1_dir}/draft.md"
case1_out="$(run_validate "$(build_plan)" "${case1_registry}" "validate_constitution" "${case1_dir}")"
case1_ok="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1]).get("ok"))
' "${case1_out}")"
case1_source="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
resolved = data.get("resolved", [])
match = [r for r in resolved if r.get("artifact") == "project_constitution"]
print(match[0].get("source_step") if match else "<not_resolved>")
' "${case1_out}")"
assert_eq "1a. validate-inputs ok=True" "True" "${case1_ok}"
assert_eq "1b. project_constitution resolved from upstream draft_constitution" \
  "draft_constitution" "${case1_source}"

# ── Case 2: no registry, intrinsic disk exists ──────────────────────
echo "Case 2: empty registry, .cap.constitution.yaml on disk → intrinsic path wins"
case2_dir="${SANDBOX}/case2"
mkdir -p "${case2_dir}"
echo "schema_version: 1" > "${case2_dir}/.cap.constitution.yaml"
case2_registry="${case2_dir}/runtime-state.json"
cat > "${case2_registry}" <<'EOF'
{"artifacts": {}, "steps": {}}
EOF
case2_out="$(run_validate "$(build_plan)" "${case2_registry}" "validate_constitution" "${case2_dir}")"
case2_ok="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1]).get("ok"))
' "${case2_out}")"
case2_source="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
resolved = data.get("resolved", [])
match = [r for r in resolved if r.get("artifact") == "project_constitution"]
print(match[0].get("source_step") if match else "<not_resolved>")
' "${case2_out}")"
assert_eq "2a. validate-inputs ok=True via intrinsic fallback" "True" "${case2_ok}"
assert_eq "2b. source_step=__request__ when intrinsic path served" \
  "__request__" "${case2_source}"

# ── Case 3: both — registry wins ────────────────────────────────────
echo "Case 3: registry has validated artifact AND disk file → registry wins"
case3_dir="${SANDBOX}/case3"
mkdir -p "${case3_dir}"
echo "schema_version: 1" > "${case3_dir}/.cap.constitution.yaml"
case3_registry="${case3_dir}/runtime-state.json"
cat > "${case3_registry}" <<EOF
{
  "artifacts": {
    "project_constitution": {
      "artifact": "project_constitution",
      "source_step": "draft_constitution",
      "path": "${case3_dir}/draft.md",
      "handoff_path": "${case3_dir}/draft.handoff.md"
    }
  },
  "steps": {
    "draft_constitution": {"execution_state": "validated"}
  }
}
EOF
echo "draft body" > "${case3_dir}/draft.md"
case3_out="$(run_validate "$(build_plan)" "${case3_registry}" "validate_constitution" "${case3_dir}")"
case3_source="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
match = [r for r in data.get("resolved", []) if r.get("artifact") == "project_constitution"]
print(match[0].get("source_step") if match else "<not_resolved>")
' "${case3_out}")"
assert_eq "3. registry wins over intrinsic disk" \
  "draft_constitution" "${case3_source}"

# ── Case 4: neither — missing ───────────────────────────────────────
echo "Case 4: neither registry nor intrinsic source → missing"
case4_dir="${SANDBOX}/case4"
mkdir -p "${case4_dir}"
case4_registry="${case4_dir}/runtime-state.json"
cat > "${case4_registry}" <<'EOF'
{"artifacts": {}, "steps": {}}
EOF
case4_out="$(run_validate "$(build_plan)" "${case4_registry}" "validate_constitution" "${case4_dir}")"
case4_ok="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1]).get("ok"))
' "${case4_out}")"
case4_missing="$(${PYTHON_BIN} -c '
import json, sys
print(",".join(json.loads(sys.argv[1]).get("missing", [])))
' "${case4_out}")"
assert_eq "4a. validate-inputs ok=False when nothing available" "False" "${case4_ok}"
assert_eq "4b. missing list includes project_constitution" \
  "project_constitution" "${case4_missing}"

echo ""
total=$((pass_count + fail_count))
echo "validate-inputs-intrinsic-vs-registry: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
