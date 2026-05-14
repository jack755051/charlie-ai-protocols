#!/usr/bin/env bash
#
# test-component-fast-binding.sh — P1b slice 6b-0 gate.
#
# Deterministic binding sanity for `component-fast` BEFORE any live
# Claude / Codex dogfood (slice 6b). Verifies the workflow can be
# resolved + planned + bound using existing cap CLI helpers without
# triggering a provider call. The point is to catch YAML / capability
# / binding errors at zero token cost so live dogfood quota is only
# spent measuring actual cost.
#
# Out of scope:
#   - No `cap workflow run` (even --dry-run; slice 6b owns A path).
#   - No provider invocation (no Claude / Codex CLI call).
#   - No expectation of "ideal" AI-skill mapping — slice 6b-0 only
#     asserts that all REQUIRED steps bind (required_unresolved=0).
#     Fallback-tier AI bindings are accepted today; tightening the
#     skill registry for compact_review / repair is a follow-up.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP="${REPO_ROOT}/scripts/cap-entry.sh"
WORKFLOW="${REPO_ROOT}/schemas/workflows/component-fast.yaml"
CAPABILITIES="${REPO_ROOT}/schemas/capabilities.yaml"
CONSTITUTION="${REPO_ROOT}/.cap.constitution.yaml"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -x "${CAP}" ]             || { echo "FAIL: ${CAP} not executable";    exit 1; }
[ -f "${WORKFLOW}" ]        || { echo "FAIL: ${WORKFLOW} missing";      exit 1; }
[ -f "${CAPABILITIES}" ]    || { echo "FAIL: ${CAPABILITIES} missing";  exit 1; }
[ -f "${CONSTITUTION}" ]    || { echo "FAIL: ${CONSTITUTION} missing";  exit 1; }

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

# ── Case 1: cap workflow show resolves component-fast ────────────────
echo "Case 1: cap workflow show component-fast resolves"
show_out="$(bash "${CAP}" workflow show component-fast 2>&1)"
show_rc=$?
assert_eq        "show exit 0"                   "0"                                          "${show_rc}"
assert_contains "show emits workflow id"          "${show_out}"  "ID:          component-fast"
assert_contains "show emits workflow version"     "${show_out}"  "VERSION:     1"
assert_contains "show emits status ready"         "${show_out}"  "STATUS:      ready"

# ── Case 2: cap workflow plan compiles to 7-phase shape ──────────────
echo ""
echo "Case 2: cap workflow plan component-fast emits 7 phases"
plan_out="$(bash "${CAP}" workflow plan component-fast 2>&1)"
plan_rc=$?
assert_eq        "plan exit 0"                   "0"                                          "${plan_rc}"
assert_contains "plan names workflow_id"          "${plan_out}"  "workflow_id: component-fast"
for phase_id in resolve_inputs render_skeleton deterministic_audit smoke_runtime compact_review fix_or_polish archive; do
  assert_contains "plan lists step ${phase_id}"   "${plan_out}"  "${phase_id} =>"
done

# ── Case 3: cap workflow bind resolves ALL steps (status=ready) ──────
#
# Slice 6b-0 accepted `binding_status: degraded` because the AI steps
# fell back to builtin-dba (no explicit skill registry entry for
# compact_review / repair). Slice 6b-1 tightened the registry so
# both AI capabilities now resolve to their `default_agent` skills
# (watcher / backend). Bind must therefore report:
#   binding_status: ready
#   total=7, resolved=7, fallback=0, required_unresolved=0
echo ""
echo "Case 3: cap workflow bind component-fast — binding_status=ready"
bind_out="$(bash "${CAP}" workflow bind component-fast 2>/dev/null)"
bind_rc=$?
assert_eq        "bind exit 0"                                "0"                                  "${bind_rc}"
assert_contains "bind reports workflow_id"                     "${bind_out}"  "workflow_id: component-fast"
assert_contains "bind binding_status: ready"                   "${bind_out}"  "binding_status: ready"
assert_contains "bind summary total=7"                         "${bind_out}"  "total=7"
assert_contains "bind summary resolved=7"                      "${bind_out}"  "resolved=7"
assert_contains "bind summary fallback=0"                      "${bind_out}"  "fallback=0"
assert_contains "bind summary required_unresolved=0"           "${bind_out}"  "required_unresolved=0"

# Each step appears in the report, and no step is blocked_by_constitution
# or fallback_available.
for step_id in resolve_inputs render_skeleton deterministic_audit smoke_runtime compact_review fix_or_polish archive; do
  assert_contains "bind lists step ${step_id}"  "${bind_out}"  "${step_id}"
done
blocked_hits="$(grep -c 'blocked_by_constitution' <<<"${bind_out}" || true)"
assert_eq "no step blocked_by_constitution"   "0"   "${blocked_hits}"
fallback_hits="$(grep -c 'fallback_available' <<<"${bind_out}" || true)"
assert_eq "no step fallback_available"        "0"   "${fallback_hits}"

# ── Case 3b: AI steps resolve to their default_agent skills ──────────
#
# Pin the exact skill mapping so a future skill-registry refactor
# can't silently route the AI steps back to builtin-dba (or any
# other shape that breaks the capabilities.yaml default_agent
# contract).
echo ""
echo "Case 3b: AI step skill mapping matches capabilities.yaml default_agent"
assert_contains "compact_review resolves to builtin-watcher"  "${bind_out}"  "compact_review (phase 5) => resolved / capability=component_repo_compact_review / skill=builtin-watcher"
assert_contains "fix_or_polish resolves to builtin-backend"   "${bind_out}"  "fix_or_polish (phase 6) => resolved / capability=component_repo_repair / skill=builtin-backend"

# ── Case 3c: shell steps resolve to builtin-shell ────────────────────
for step_pair in \
  "resolve_inputs|component_fast_inputs" \
  "render_skeleton|deterministic_scaffold" \
  "deterministic_audit|deterministic_compliance_checklist" \
  "smoke_runtime|runtime_smoke"
do
  step_id="${step_pair%|*}"
  cap_name="${step_pair#*|}"
  assert_contains "shell step ${step_id} resolves to builtin-shell" \
    "${bind_out}" \
    "${step_id} (phase $(case "${step_id}" in
      resolve_inputs) echo 1 ;; render_skeleton) echo 2 ;;
      deterministic_audit) echo 3 ;; smoke_runtime) echo 4 ;;
    esac)) => resolved / capability=${cap_name} / skill=builtin-shell"
done

# ── Case 4: every workflow capability is declared in schemas/capabilities.yaml ─
echo ""
echo "Case 4: every workflow capability is recognised"
cap_check="$("${PYTHON_BIN}" - "${WORKFLOW}" "${CAPABILITIES}" <<'PY'
import sys
import yaml

workflow_data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
caps_data = yaml.safe_load(open(sys.argv[2], encoding="utf-8")) or {}
declared = set((caps_data.get("capabilities") or {}).keys())

missing = []
for step in workflow_data.get("steps") or []:
    cap = step.get("capability")
    if isinstance(cap, str) and cap and cap not in declared:
        missing.append(f"{step.get('id')}->{cap}")
print(",".join(missing))
PY
)"
assert_eq "no undeclared capability reference" "" "${cap_check}"

# ── Case 5: every shell step's script path exists on disk ────────────
#
# After slice 6a both wrapper scripts (resolve / smoke) are on disk,
# so this case asserts the complete substrate is bound to real files.
# Slice 6b dogfood would otherwise halt at step 1 with a missing
# script error.
echo ""
echo "Case 5: every shell-step script exists on disk"
shell_scripts="$("${PYTHON_BIN}" - "${WORKFLOW}" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
for step in data.get("steps") or []:
    if step.get("executor") == "shell":
        script = step.get("script") or ""
        print(f"{step['id']}|{script}")
PY
)"
while IFS='|' read -r step_id script; do
  [ -n "${step_id}" ] || continue
  if [ -x "${REPO_ROOT}/${script}" ]; then
    echo "  PASS: shell-step ${step_id} script +x: ${script}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: shell-step ${step_id} script missing or not +x: ${script}"
    fail_count=$((fail_count + 1))
  fi
done <<<"${shell_scripts}"

# ── Case 6: AI step count == 2 (P1a budget regression) ───────────────
echo ""
echo "Case 6: AI step count == 2"
ai_count="$("${PYTHON_BIN}" - "${WORKFLOW}" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
ai_steps = [s for s in (data.get("steps") or []) if s.get("executor") == "ai"]
print(len(ai_steps))
PY
)"
assert_eq "AI step count is 2 (matches P1a memo)" "2" "${ai_count}"

# ── Case 7: no operational coupling to project-strict pipelines ──────
echo ""
echo "Case 7: no operational dependency on project-strict pipelines"
coupling="$("${PYTHON_BIN}" - "${WORKFLOW}" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
strict_ids = {
    "project-spec-pipeline",
    "project-implementation-pipeline",
    "project-qa-pipeline",
}
strict_caps = {
    "task_constitution_persistence",
    "code_structure_audit",
    "business_analysis",
    "database_api_design",
    "ui_design",
}

hits = []
for step in data.get("steps") or []:
    if step.get("capability") in strict_caps:
        hits.append(f"step {step.get('id')!r} uses strict capability {step.get('capability')!r}")
    for need in step.get("needs") or []:
        if need in strict_ids:
            hits.append(f"step {step.get('id')!r} needs strict pipeline {need!r}")
    script = step.get("script") or ""
    for sid in strict_ids:
        if sid in script:
            hits.append(f"step {step.get('id')!r} script references {sid!r}")

gov = data.get("governance") or {}
if gov.get("required_upstream_artifacts"):
    hits.append("governance.required_upstream_artifacts is set (coupling)")

print(",".join(hits))
PY
)"
assert_eq "no operational coupling" "" "${coupling}"

# ── Case 8: project constitution allowlists every workflow capability ─
#
# Regression for the .cap.constitution.yaml amendment that landed
# alongside this test. Without these entries the workflow binds with
# binding_status=blocked and 6 of 7 steps come back as
# blocked_by_constitution — exactly the failure mode this slice
# closes.
echo ""
echo "Case 8: .cap.constitution.yaml allowlists every workflow capability"
cap_gap="$("${PYTHON_BIN}" - "${WORKFLOW}" "${CONSTITUTION}" <<'PY'
import sys
import yaml

workflow_data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
constitution = yaml.safe_load(open(sys.argv[2], encoding="utf-8")) or {}

# Project constitution wraps the allowlist under a top-level project
# section; walk it generically so the test does not depend on the
# exact key name.
def collect_allowed(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "allowed_capabilities" and isinstance(value, list):
                for item in value:
                    if isinstance(item, str):
                        yield item
            else:
                yield from collect_allowed(value)
    elif isinstance(node, list):
        for entry in node:
            yield from collect_allowed(entry)

allowed = set(collect_allowed(constitution))
needed_caps = {
    step.get("capability")
    for step in workflow_data.get("steps") or []
    if isinstance(step.get("capability"), str)
}
missing = sorted(needed_caps - allowed)
print(",".join(missing))
PY
)"
assert_eq "no capability missing from project constitution" "" "${cap_gap}"

# ── Case 9: bind / plan / show do not call a provider ────────────────
#
# These are deterministic metadata commands; they MUST NOT shell out
# to claude / codex. Scan the captured stdout+stderr for telltale
# provider invocation strings. (We cannot easily intercept fork() in
# a pure-shell test; this string scan is the practical proxy.)
echo ""
echo "Case 9: bind / plan / show emit no provider invocation traces"
combined="${show_out}
${plan_out}
${bind_out}"
provider_hits="$(grep -iE 'invoking (claude|codex)|provider call|api.anthropic|api.openai' <<<"${combined}" || true)"
assert_eq "no provider invocation in metadata output" "" "${provider_hits}"

echo ""
total=$((pass_count + fail_count))
echo "component-fast-binding: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
