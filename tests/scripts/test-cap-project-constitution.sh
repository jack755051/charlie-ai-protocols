#!/usr/bin/env bash
#
# test-cap-project-constitution.sh — Smoke for `cap project constitution` (P2 #2-b).
#
# Coverage (8 cases):
#   Case 1: --dry-run + --prompt → exit 0, status=planned, no disk writes
#   Case 2: --from-file (JSON, valid) → exit 0, status=ok, 4-part snapshot
#   Case 3: --from-file (YAML, valid) → exit 0, status=ok, snapshot also written
#   Case 4: --from-file (JSON, invalid) → exit 1, status=failed, all 4 still written
#   Case 5: --from-file path missing → exit 1, no snapshot dir
#   Case 6: --from-file payload not a mapping → exit 1
#   Case 7: missing .cap.project.yaml → exit 1
#   Case 8: invalid --stamp shape → exit 1
#
# Out of scope (deferred per P2 #2-b ratification Q1 = A):
#   - prompt-mode end-to-end (real `cap workflow run project-constitution`
#     + AI agent). The integration test lands in P2 #8 once a deterministic
#     workflow stub is available.
#
# Sandbox: every case writes under a unique CAP_HOME inside ${SANDBOX} so a
# failure in one case cannot leak into another's project storage.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_PROJECT="${REPO_ROOT}/scripts/cap-project.sh"

[ -x "${CAP_PROJECT}" ] || { echo "FAIL: ${CAP_PROJECT} not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-test-project-constitution.XXXXXX)"
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

# Run cap-project.sh constitution in a sandboxed env. Returns
# "STDOUT|STDERR|EXIT".
run_constitution() {
  local project_root="$1" cap_home="$2"
  shift 2
  local out err code tmp_out tmp_err
  tmp_out="$(mktemp)"; tmp_err="$(mktemp)"
  set +e
  bash "${CAP_PROJECT}" constitution \
    --project-root "${project_root}" \
    --cap-home "${cap_home}" \
    "$@" >"${tmp_out}" 2>"${tmp_err}"
  code=$?
  set -e
  out="$(cat "${tmp_out}")"; err="$(cat "${tmp_err}")"
  rm -f "${tmp_out}" "${tmp_err}"
  printf '%s|%s|%s' "${out}" "${err}" "${code}"
}

# Helper: emit a minimally-valid Project Constitution payload as JSON.
emit_valid_json() {
  cat <<'EOF'
{
  "schema_version": 1,
  "constitution_id": "smoke-cap",
  "project_id": "smoke",
  "name": "Smoke Constitution",
  "summary": "minimal valid sample for runner smoke",
  "source_of_truth": {
    "project_constitution": ".cap.constitution.yaml",
    "project_config": ".cap.project.yaml",
    "skill_registry": ".cap.skills.yaml"
  },
  "runtime_workspace": {
    "root": "~/.cap",
    "stores": ["projects"]
  },
  "binding_policy": {
    "defaults": {"binding_mode": "strict", "missing_policy": "halt"},
    "allowed_capabilities": ["task_constitution_planning"]
  },
  "workflow_policy": {
    "enforce_allowed_source_roots": true,
    "allowed_source_roots": ["schemas/workflows"]
  }
}
EOF
}

# Helper: emit a minimally-valid Project Constitution payload as YAML.
emit_valid_yaml() {
  cat <<'EOF'
schema_version: 1
constitution_id: smoke-cap-yaml
project_id: smoke
name: Smoke Constitution (YAML)
summary: minimal valid sample, YAML form
source_of_truth:
  project_constitution: .cap.constitution.yaml
  project_config: .cap.project.yaml
  skill_registry: .cap.skills.yaml
runtime_workspace:
  root: ~/.cap
  stores: [projects]
binding_policy:
  defaults: {binding_mode: strict, missing_policy: halt}
  allowed_capabilities: [task_constitution_planning]
workflow_policy:
  enforce_allowed_source_roots: true
  allowed_source_roots: [schemas/workflows]
EOF
}

# Helper: bootstrap a fake project root with .cap.project.yaml.
init_project_root() {
  local root="$1" id="$2"
  mkdir -p "${root}"
  cat > "${root}/.cap.project.yaml" <<EOF
project_id: ${id}
EOF
}

STAMP_OK="20260503T120000Z"

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: --dry-run + --prompt → status=planned, no disk writes"
c1_root="${SANDBOX}/c1-repo"; c1_home="${SANDBOX}/c1-cap"
init_project_root "${c1_root}" "smoke"

result="$(run_constitution "${c1_root}" "${c1_home}" \
  --prompt "build me a constitution" --dry-run --stamp "${STAMP_OK}")"
out1="${result%%|*}"; rest="${result#*|}"; exit1="${rest##*|}"

assert_eq "case 1 exit 0" "0" "${exit1}"
assert_contains "case 1 status=planned" "status=planned" "${out1}"
assert_contains "case 1 mode=prompt" "mode=prompt" "${out1}"
assert_contains "case 1 dry_run=true" "dry_run=true" "${out1}"
# plan() never writes to disk — the snapshot dir must not exist.
assert_file_absent "case 1 snapshot dir not created" \
  "${c1_home}/projects/smoke/constitutions/project/${STAMP_OK}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: --from-file (JSON, valid) → status=ok, 4-part snapshot"
c2_root="${SANDBOX}/c2-repo"; c2_home="${SANDBOX}/c2-cap"
init_project_root "${c2_root}" "smoke"
c2_input="${SANDBOX}/c2-input.json"
emit_valid_json > "${c2_input}"

result="$(run_constitution "${c2_root}" "${c2_home}" \
  --from-file "${c2_input}" --stamp "${STAMP_OK}")"
out2="${result%%|*}"; rest="${result#*|}"; exit2="${rest##*|}"

assert_eq "case 2 exit 0" "0" "${exit2}"
assert_contains "case 2 status=ok" "status=ok" "${out2}"
assert_contains "case 2 mode=from_file" "mode=from_file" "${out2}"
assert_contains "case 2 validation ok=True" "validation: ok=True" "${out2}"
c2_dir="${c2_home}/projects/smoke/constitutions/project/${STAMP_OK}"
assert_file_exists "case 2 markdown" "${c2_dir}/project-constitution.md"
assert_file_exists "case 2 json" "${c2_dir}/project-constitution.json"
assert_file_exists "case 2 validation" "${c2_dir}/validation.json"
assert_file_exists "case 2 source-prompt" "${c2_dir}/source-prompt.txt"

# Validation file should record status=ok.
v2="$(cat "${c2_dir}/validation.json" 2>/dev/null || echo '{}')"
assert_contains "case 2 validation.json status=ok" '"status": "ok"' "${v2}"

# Source prompt should reference --from-file ingestion path.
sp2="$(cat "${c2_dir}/source-prompt.txt" 2>/dev/null || echo '')"
assert_contains "case 2 source-prompt notes ingestion" "Imported via" "${sp2}"

# JSON output should round-trip as valid JSON via --format json.
result_json="$(run_constitution "${c2_root}" "${c2_home}" \
  --from-file "${c2_input}" --stamp "20260503T120030Z" --format json)"
out2j="${result_json%%|*}"; exit2j="${result_json##*|}"
assert_eq "case 2 --format json exit 0" "0" "${exit2j}"
parsed_status="$(printf '%s' "${out2j}" | python3 -c '
import json, sys
print(json.load(sys.stdin).get("status", ""))
')"
assert_eq "case 2 JSON envelope status=ok" "ok" "${parsed_status}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: --from-file (YAML, valid) → status=ok"
c3_root="${SANDBOX}/c3-repo"; c3_home="${SANDBOX}/c3-cap"
init_project_root "${c3_root}" "smoke"
c3_input="${SANDBOX}/c3-input.yaml"
emit_valid_yaml > "${c3_input}"

result="$(run_constitution "${c3_root}" "${c3_home}" \
  --from-file "${c3_input}" --stamp "${STAMP_OK}")"
out3="${result%%|*}"; rest="${result#*|}"; exit3="${rest##*|}"

assert_eq "case 3 exit 0" "0" "${exit3}"
assert_contains "case 3 status=ok" "status=ok" "${out3}"
c3_dir="${c3_home}/projects/smoke/constitutions/project/${STAMP_OK}"
assert_file_exists "case 3 json materialised from yaml" "${c3_dir}/project-constitution.json"

# YAML payload should be re-emitted as JSON inside the snapshot — verify
# by parsing the persisted artefact.
parsed_id="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get("constitution_id", ""))
' "${c3_dir}/project-constitution.json")"
assert_eq "case 3 yaml→json constitution_id" "smoke-cap-yaml" "${parsed_id}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: --from-file (invalid schema) → exit 1, all 4 artefacts present"
c4_root="${SANDBOX}/c4-repo"; c4_home="${SANDBOX}/c4-cap"
init_project_root "${c4_root}" "smoke"
c4_input="${SANDBOX}/c4-input.json"
# Missing `binding_policy` and `workflow_policy` blocks → schema rejection.
cat > "${c4_input}" <<'EOF'
{
  "schema_version": 1,
  "constitution_id": "broken",
  "project_id": "smoke",
  "name": "Broken",
  "summary": "missing required nested blocks",
  "source_of_truth": {
    "project_constitution": ".cap.constitution.yaml",
    "project_config": ".cap.project.yaml",
    "skill_registry": ".cap.skills.yaml"
  },
  "runtime_workspace": {
    "root": "~/.cap",
    "stores": ["projects"]
  }
}
EOF

result="$(run_constitution "${c4_root}" "${c4_home}" \
  --from-file "${c4_input}" --stamp "${STAMP_OK}")"
out4="${result%%|*}"; rest="${result#*|}"; exit4="${rest##*|}"

assert_eq "case 4 exit 1" "1" "${exit4}"
assert_contains "case 4 status=failed" "status=failed" "${out4}"
assert_contains "case 4 validation ok=False" "validation: ok=False" "${out4}"
c4_dir="${c4_home}/projects/smoke/constitutions/project/${STAMP_OK}"
# Per Q2 ratification: all four artefacts still land on disk.
assert_file_exists "case 4 markdown still written" "${c4_dir}/project-constitution.md"
assert_file_exists "case 4 json still written" "${c4_dir}/project-constitution.json"
assert_file_exists "case 4 validation still written" "${c4_dir}/validation.json"
assert_file_exists "case 4 source-prompt still written" "${c4_dir}/source-prompt.txt"
v4="$(cat "${c4_dir}/validation.json" 2>/dev/null || echo '{}')"
assert_contains "case 4 validation.json status=failed" '"status": "failed"' "${v4}"
assert_contains "case 4 validation.json lists errors" "is a required property" "${v4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: --from-file path missing → exit 1, no snapshot dir"
c5_root="${SANDBOX}/c5-repo"; c5_home="${SANDBOX}/c5-cap"
init_project_root "${c5_root}" "smoke"

result="$(run_constitution "${c5_root}" "${c5_home}" \
  --from-file "${SANDBOX}/no-such-file.json" --stamp "${STAMP_OK}")"
err5="${result#*|}"; err5="${err5%|*}"; exit5="${result##*|}"

assert_eq "case 5 exit 1" "1" "${exit5}"
assert_contains "case 5 stderr names missing file" "does not exist" "${err5}"
assert_file_absent "case 5 no snapshot dir" \
  "${c5_home}/projects/smoke/constitutions/project/${STAMP_OK}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: --from-file payload not a mapping → exit 1"
c6_root="${SANDBOX}/c6-repo"; c6_home="${SANDBOX}/c6-cap"
init_project_root "${c6_root}" "smoke"
c6_input="${SANDBOX}/c6-input.json"
echo '["not", "a", "mapping"]' > "${c6_input}"

result="$(run_constitution "${c6_root}" "${c6_home}" \
  --from-file "${c6_input}" --stamp "${STAMP_OK}")"
err6="${result#*|}"; err6="${err6%|*}"; exit6="${result##*|}"

assert_eq "case 6 exit 1" "1" "${exit6}"
assert_contains "case 6 stderr explains mapping requirement" "mapping" "${err6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: missing .cap.project.yaml → exit 1"
c7_root="${SANDBOX}/c7-no-config"; c7_home="${SANDBOX}/c7-cap"
mkdir -p "${c7_root}"  # deliberately do NOT write .cap.project.yaml
c7_input="${SANDBOX}/c7-input.json"
emit_valid_json > "${c7_input}"

result="$(run_constitution "${c7_root}" "${c7_home}" \
  --from-file "${c7_input}" --stamp "${STAMP_OK}")"
err7="${result#*|}"; err7="${err7%|*}"; exit7="${result##*|}"

assert_eq "case 7 exit 1" "1" "${exit7}"
assert_contains "case 7 stderr names .cap.project.yaml" ".cap.project.yaml" "${err7}"
assert_contains "case 7 stderr suggests cap project init" "cap project init" "${err7}"

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: invalid --stamp shape → exit 1"
c8_root="${SANDBOX}/c8-repo"; c8_home="${SANDBOX}/c8-cap"
init_project_root "${c8_root}" "smoke"
c8_input="${SANDBOX}/c8-input.json"
emit_valid_json > "${c8_input}"

result="$(run_constitution "${c8_root}" "${c8_home}" \
  --from-file "${c8_input}" --stamp "bad-shape")"
err8="${result#*|}"; err8="${err8%|*}"; exit8="${result##*|}"

assert_eq "case 8 exit 1" "1" "${exit8}"
assert_contains "case 8 stderr explains stamp shape" "stamp" "${err8}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
